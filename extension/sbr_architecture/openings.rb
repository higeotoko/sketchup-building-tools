# frozen_string_literal: true

require 'securerandom'

module Higeotoko
  module SbrArchitecture
    module Openings
      API = SbrArchitecture
      TYPES = { 'window' => '窓開口', 'door' => '扉開口' }.freeze
      module_function

      def fields(kind)
        kind == 'window' ? [1650, 1100, 900] : [800, 2000, 0]
      end

      def parameters(kind, values)
        TYPES.fetch(kind)
        sill = kind == 'door' ? 0.0 : Layout.mm(values['sill'], '腰高')
        raise ArgumentError, '腰高は0 mm以上にしてください。' if sill.negative? || (sill.positive? && sill < Layout::MIN_MM)

        {
          'kind' => kind,
          'width' => Layout.mm(values['width'], '開口幅', positive: true),
          'height' => Layout.mm(values['height'], '開口高さ', positive: true),
          'sill' => sill,
          'mark' => values['mark'].to_s.strip
        }
      end

      def position(opening)
        x = opening.fetch('offset')
        z = opening.fetch('sill')
        [x - opening.fetch('width') / 2, x + opening.fetch('width') / 2, z, z + opening.fetch('height')]
      end

      def segment(points, index)
        a, b = points.fetch(index), points.fetch(index + 1)
        x, y = b.zip(a).map { |ending, start| ending - start }
        length = Math.hypot(x, y)
        [a, [x / length, y / length]]
      end

      def projection(point, origin, axis)
        (point[0] - origin[0]) * axis[0] + (point[1] - origin[1]) * axis[1]
      end

      def validate(params, profiles)
        grouped = params.fetch('openings', []).group_by { |opening| opening.fetch('segment') }
        grouped.each do |index, openings|
          raise ArgumentError, '開口のある壁区間が見つかりません。' unless index.between?(0, profiles.size - 1)

          origin, axis = segment(params.fetch('points'), index)
          left_a, right_a, right_b, left_b = profiles.fetch(index).map { |p| projection(p, origin, axis) }
          lower, upper = [left_a, right_a].max, [left_b, right_b].min
          openings.each do |opening|
            x1, x2, z1, z2 = position(opening)
            if x1 - lower < Layout::MIN_MM || upper - x2 < Layout::MIN_MM ||
               z1.negative? || params.fetch('height') - z2 < Layout::MIN_MM
              raise ArgumentError, '開口が壁の端または天端にかかります。位置・寸法を調整してください。'
            end
          end
          openings.combination(2).each do |first, second|
            ax, bx, az, bz = position(first)
            cx, dx, cz, dz = position(second)
            next if bx + Layout::MIN_MM <= cx || dx + Layout::MIN_MM <= ax ||
                    bz + Layout::MIN_MM <= cz || dz + Layout::MIN_MM <= az

            raise ArgumentError, '開口同士が重なるか、近すぎます。'
          end
        end
        grouped
      end

      def side_loop(a, b, height, doors, at)
        [at.call(a, 0), *doors.flat_map { |x1, x2, _, z| [[x1, 0], [x1, z], [x2, z], [x2, 0]].map { |x, h| at.call(x, h) } },
         at.call(b, 0), at.call(b, height), at.call(a, height)]
      end

      def write_segment(group, params, profile, index, openings)
        origin, axis = segment(params.fetch('points'), index)
        xy = profile.map { |p| [projection(p, origin, axis), projection(p, origin, [-axis[1], axis[0]])] }
        left_a, right_a, right_b, left_b = xy
        height = params.fetch('height')
        at = lambda do |offset, lateral, z|
          API.point(origin[0] + axis[0] * offset - axis[1] * lateral,
                    origin[1] + axis[1] * offset + axis[0] * lateral, z)
        end
        left = ->(x, z) { at.call(x, left_a[1], z) }
        right = ->(x, z) { at.call(x, right_a[1], z) }
        doors, windows = openings.map { |opening| position(opening) }.sort_by(&:first).partition { |_, _, z, _| z.zero? }
        group.entities.build do |builder|
          [[right_a, right_b, right, false], [left_a, left_b, left, true]].each do |a, b, side, reverse|
            outer = side_loop(a[0], b[0], height, doors, side)
            holes = windows.map do |x1, x2, z1, z2|
              [[x1, z1], [x1, z2], [x2, z2], [x2, z1]].map { |x, z| side.call(x, z) }
            end
            outer, holes = outer.reverse, holes.map(&:reverse) if reverse
            builder.add_face(outer, holes: holes)
          end
          builder.add_face([left.call(left_a[0], height), right.call(right_a[0], height),
                            right.call(right_b[0], height), left.call(left_b[0], height)])
          builder.add_face([left.call(left_a[0], 0), right.call(right_a[0], 0),
                            right.call(right_a[0], height), left.call(left_a[0], height)])
          builder.add_face([right.call(right_b[0], 0), left.call(left_b[0], 0),
                            left.call(left_b[0], height), right.call(right_b[0], height)])
          starts = [[left_a[0], right_a[0]], *doors.map { |_, x2, _, _| [x2, x2] }]
          ends = [*doors.map { |x1, _, _, _| [x1, x1] }, [left_b[0], right_b[0]]]
          starts.zip(ends).each do |(a, b), (c, d)|
            builder.add_face([left.call(a, 0), left.call(c, 0), right.call(d, 0), right.call(b, 0)])
          end
          (doors + windows).each do |x1, x2, z1, z2|
            builder.add_face([right.call(x1, z1), left.call(x1, z1), left.call(x1, z2), right.call(x1, z2)])
            builder.add_face([left.call(x2, z1), right.call(x2, z1), right.call(x2, z2), left.call(x2, z2)])
            builder.add_face([left.call(x1, z2), left.call(x2, z2), right.call(x2, z2), right.call(x1, z2)])
            if z1.positive?
              builder.add_face([right.call(x1, z1), right.call(x2, z1), left.call(x2, z1), left.call(x1, z1)])
            end
          end
        end
        raise ArgumentError, '開口付きの壁をソリッドとして作成できませんでした。' unless group.manifold? && group.volume.positive?

        group.entities.each { |entity| entity.layer = group.model.layers[0] }
      end

      class Placement
        def initialize(model, params)
          @model, @params = model, params
          @input = Sketchup::InputPoint.new
        end

        def activate
          Sketchup.set_status_text("#{TYPES.fetch(@params.fetch('kind'))}の中心を壁面上でクリック。Escで終了。", SB_PROMPT)
        end

        def onMouseMove(_flags, x, y, view)
          @candidate = nil
          @valid = false
          @input.pick(view, x, y)
          path = @input.instance_path&.to_a if @input.valid? && @input.face
          wall = path&.first
          if wall.is_a?(Sketchup::Group) && !wall.locked? && wall.get_attribute(API::DICT, 'kind') == 'wall' &&
             !path[1].is_a?(Sketchup::ComponentInstance)
            params = JSON.parse(wall.get_attribute(API::DICT, 'parameters'))
            index = path[1].is_a?(Sketchup::Group) ? wall.entities.grep(Sketchup::Group).index(path[1]) : 0
            local = @input.position.transform(wall.transformation.inverse).to_a.map(&:to_mm)
            origin, axis = Openings.segment(params.fetch('points'), index)
            offset = Openings.projection(local, origin, axis).round(1)
            opening = @params.merge('segment' => index, 'offset' => offset)
            profiles = API.wall_profiles(params)
            pending = params.merge('openings' => params.fetch('openings', []) + [opening])
            @candidate = [wall, params, pending, opening, profiles[index]]
            Openings.validate(pending, profiles)
            @valid = true
          end
        rescue ArgumentError, IndexError, KeyError
          @valid = false
        ensure
          view.invalidate
        end

        def onLButtonDown(flags, x, y, view)
          onMouseMove(flags, x, y, view)
          return unless @candidate

          API.report_errors do
            API.top_level!(@model)
            wall, previous, pending, opening = @candidate
            Openings.validate(pending, API.wall_profiles(previous))
            opening['id'] = SecureRandom.uuid
            API.regenerate(wall, pending)
            @model.selection.clear
            @model.selection.add(wall)
            @model.select_tool(nil)
          end
        end

        def draw(view)
          return unless @candidate

          wall, params, _, opening, profile = @candidate
          origin, axis = Openings.segment(params.fetch('points'), opening.fetch('segment'))
          perpendicular = [-axis[1], axis[0]]
          x1, x2, z1, z2 = Openings.position(opening)
          view.drawing_color = @valid ? Sketchup::Color.new(0, 135, 121) : Sketchup::Color.new(205, 63, 47)
          view.line_width = 3
          [profile[0], profile[1]].each do |p|
            y = Openings.projection(p, origin, perpendicular)
            loop = [[x1, z1], [x2, z1], [x2, z2], [x1, z2]].map do |x, z|
              API.point(origin[0] + axis[0] * x + perpendicular[0] * y,
                        origin[1] + axis[1] * x + perpendicular[1] * y, z).transform(wall.transformation)
            end
            view.draw(GL_LINE_LOOP, loop)
          end
        end

        def getExtents
          @model.bounds
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
