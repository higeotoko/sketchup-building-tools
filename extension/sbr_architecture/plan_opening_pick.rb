# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Openings
      class PlanPick
        Segment = Struct.new(:wall, :params, :index, :profile, :polygon, :at, :inverse, :cut_height)
        Hit = Struct.new(:segment, :offset, :opening)

        def self.top?(view)
          !view.camera.perspective? && view.camera.direction.z < -0.9999
        end

        def self.active_spec(model)
          return unless top?(model.active_view)

          page = model.pages.selected_page
          raw = page&.get_attribute(Drawings::META, 'spec')
          data = JSON.parse(raw) if raw
          data if data && data['kind'] == 'plan'
        end

        def self.for(model, level, height)
          return unless top?(model.active_view)

          data = active_spec(model)
          cut = data ? Drawings.geometry(model, data).last : (API.levels(model)[level] || Layout.mm(height, '作図高さ')) + 1100
          new(model, cut, data ? nil : level)
        end

        def initialize(model, cut, level)
          @model, @cut, @level, @page = model, cut, level, model.pages.selected_page
          @projected_walls = self.class.active_spec(model) ? @page.get_attribute(Drawings::META, 'plan_projected_walls', []) : []
          @segments = model.entities.grep(Sketchup::Group).flat_map do |wall|
            next [] unless Follow.kind(wall) == 'wall' && editable_wall?(wall)

            params = Follow.parameters(wall)
            next [] if level && !level.empty? && params['level'] && params['level'] != level

            transform = wall.transformation
            next [] unless PlanLinework.upright?(transform)

            inverse = transform.inverse
            z = API.point(0, 0, cut).transform(inverse).z.to_mm
            next [] unless z >= 0 && z < params.fetch('height')

            API.wall_profiles(params).map.with_index do |profile, index|
              _, local = PlanLinework.basis(params, profile, index)
              at = ->(x, lateral) { local.call(x, lateral, z).transform(transform) }
              polygon = profile.map { |x, y| API.point(x, y, z).transform(transform) }
              Segment.new(wall, params, index, profile, polygon, at, inverse, z)
            end
          end
        end

        def editable_wall?(wall)
          wall.valid? && !wall.locked? && wall.layer.visible? &&
            (!wall.hidden? || @projected_walls.include?(wall.persistent_id))
        end

        def refresh
          self.class.new(@model, @cut, @level)
        end

        def current?(view)
          self.class.top?(view) && @model.pages.selected_page == @page
        end

        def hit(view, x, y, existing: false, axis: nil)
          return unless current?(view)

          point = Geom.intersect_line_plane(view.pickray(x, y), [API.point(0, 0, @cut), Z_AXIS])
          return unless point

          tolerance = [view.pixels_to_model(5, point), 100.mm].min
          @segments.filter_map do |segment|
            next unless editable_wall?(segment.wall)

            axis_vector = segment.polygon[3] - segment.polygon[0]
            next if axis_vector.length < 1.mm
            next if axis && !axis_vector.parallel?(axis == :x ? X_AXIS : Y_AXIS)

            distance = distance_to_wall(point, segment.polygon)
            next if distance > tolerance

            local = point.transform(segment.inverse).to_a.map(&:to_mm)
            origin, axis = Openings.segment(segment.params.fetch('points'), segment.index)
            offset = Openings.projection(local, origin, axis).round(1)
            opening = opening_at(segment, offset, local[2]) if existing
            next if existing && !opening

            center = Geom.linear_combination(0.5, segment.polygon[0], 0.5, segment.polygon[1])
            [Hit.new(segment, offset, opening), distance, (point - center).cross(axis_vector.normalize).length]
          end.min_by { |_, distance, center| [distance, center] }&.first
        end

        def opening_at(segment, offset, z)
          segment.params.fetch('openings', []).find do |opening|
            x1, x2, bottom, top = Openings.position(opening)
            opening['segment'] == segment.index && offset.between?(x1, x2) && bottom <= z && z < top
          end
        end

        def validate_opening!(hit, opening)
          _, _, bottom, top = Openings.position(opening)
          z = hit.segment.cut_height
          return if bottom <= z && z < top

          raise ArgumentError, '平面の切断高さが開口に掛かりません。腰高・開口高さか平面の切断高さを調整してください。'
        end

        def distance_to_wall(point, polygon)
          return 0 if Geom.point_in_polygon_2D(point, polygon, true)

          polygon.zip(polygon.rotate).map do |a, b|
            edge = b - a
            next point.distance(a) if edge.length.zero?

            t = ((point - a).dot(edge) / edge.dot(edge)).clamp(0, 1)
            point.distance(Geom.linear_combination(1 - t, a, t, b))
          end.min
        end

        def draw(view, hit, opening, fixed: false)
          segment = hit.segment
          origin, axis = Openings.segment(segment.params.fetch('points'), segment.index)
          left, right = segment.profile.first(2).map { |p| Openings.projection(p, origin, [-axis[1], axis[0]]) }
          at = ->(x, lateral) { view.screen_coords(segment.at.call(x, lateral)) }
          x1, x2, = Openings.position(opening)
          corners = [[x1, left], [x1, right], [x2, right], [x2, left]].map { |p| at.call(*p) }
          if fixed
            view.drawing_color = Sketchup::Color.new(0, 135, 121, 65)
            view.draw2d(GL_POLYGON, corners)
            view.drawing_color = Sketchup::Color.new(0, 135, 121)
          end
          view.draw2d(GL_LINE_LOOP, corners)
          outside = Layout.wall_outside(segment.params)
          Openings.symbol_paths(opening, left, right, segment.params.fetch('points'), outside: outside).each do |path|
            view.draw2d(GL_LINE_STRIP, path.map { |p| at.call(*p) })
          end
        end
      end

      class PlanEdit
        def initialize(model, picker, &edit)
          @model, @picker, @edit = model, picker, edit
        end

        def activate
          Sketchup.set_status_text('平面に表示されている窓・扉の開口をクリック。Escで終了。', SB_PROMPT)
        end

        def onMouseMove(_flags, x, y, view)
          @hit = @picker.hit(view, x, y, existing: true)
          view.invalidate
        end

        def onLButtonDown(flags, x, y, view)
          onMouseMove(flags, x, y, view)
          return unless @hit

          @model.select_tool(nil)
          @edit.call(@hit.segment.wall, @hit.opening.fetch('id'))
        end

        def draw(view)
          return unless @hit

          view.drawing_color = Sketchup::Color.new(0, 135, 121)
          view.line_width = 2
          @picker.draw(view, @hit, @hit.opening)
        end

        def onCancel(reason, _view)
          @model.select_tool(nil) if reason.zero?
        end

        def deactivate(view)
          view.invalidate
        end
      end
    end
  end
end
