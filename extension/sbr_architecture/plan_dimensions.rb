# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module PlanDimensions
      API = SbrArchitecture
      KEY = 'plan_dimensions'
      Anchor = Struct.new(:ref, :a, :b, :first, :last) do
        def at(t)
          a.zip(b).map { |p, q| p + (q - p) * t }
        end

        def reference(t)
          first ? ref.merge('station' => (first + (last - first) * t).round(8)) : ref
        end

        def locate(station)
          return a unless first

          t = (station - first) / (last - first)
          at(t.clamp(0, 1)) if t.between?(-0.000001, 1.000001)
        end
      end
      module_function

      def entries(page)
        page ? JSON.parse(page.get_attribute(Drawings::META, KEY, '[]')) : []
      end

      def wall_faces(wall, cut)
        transform = wall.transformation
        return [] unless PlanLinework.upright?(transform)

        z = API.point(0, 0, cut).transform(transform.inverse).z.to_mm
        params = Follow.parameters(wall)
        path = params.fetch('points')
        PlanLinework.slices(params, z).each_with_index.flat_map do |(loops, _, _, left, right), segment|
          origin, axis = Openings.segment(path, segment)
          lateral = [-axis[1], axis[0]]
          finish = Openings.projection(path.fetch(segment + 1), origin, axis)
          loops.flat_map do |loop|
            loop.zip(loop.rotate).filter_map do |p, q|
              local = [p, q].map { |point| xy(point) }
              offsets = local.map { |point| Openings.projection(point, origin, lateral) }
              side = [left, right].index { |value| offsets.all? { |offset| (offset - value).abs < 0.001 } }
              next unless side

              first, last = local.map { |point| Openings.projection(point, origin, axis) / finish }
              next if (last - first).abs < 1e-8

              ref = { 'id' => wall.persistent_id, 'segment' => segment, 'side' => side,
                      'path_size' => path.size, 'direction' => axis.map { |value| value.round(6) } }
              Anchor.new(ref, xy(p.transform(transform)), xy(q.transform(transform)), first, last)
            end
          end
        end
      end

      def column_center(column, cut)
        box = column.bounds
        return [] unless box.valid? && box.min.z.to_mm < cut && cut <= box.max.z.to_mm

        # Steel members are internally extruded on local X. All catalog
        # columns use the member origin as the center of the foot.
        origin = column.transformation.origin
        vertical = Follow.parameters(column)['system'] == 'steel' ? column.transformation.xaxis : column.transformation.zaxis
        return [] unless vertical.z.positive? && vertical.parallel?(Z_AXIS)

        [Anchor.new({ 'id' => column.persistent_id }, xy(origin), xy(origin))]
      end

      def references(model, cut, hidden, ids: nil)
        groups = ids ? ids.map { |id| model.find_entity_by_persistent_id(id) } : model.entities.grep(Sketchup::Group)
        groups.flat_map do |group|
          next [] unless group.is_a?(Sketchup::Group) && !hidden.include?(group.persistent_id) && group.layer.visible?

          case Follow.kind(group)
          when 'wall' then wall_faces(group, cut)
          when 'column' then column_center(group, cut)
          else []
          end
        end.group_by(&:ref)
      end

      def xy(point)
        [point.x.to_mm, point.y.to_mm]
      end

      def foot(point, a, b)
        dx, dy = b[0] - a[0], b[1] - a[1]
        size = dx * dx + dy * dy
        return 0.0 if size.zero?

        ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy).fdiv(size)
      end

      def endpoints(refs, anchors)
        faces = refs.map { |ref| anchors.fetch(ref.except('station'), []) }
        return if faces.any?(&:empty?)

        # Measure normal to a finish face. When a column is the second
        # reference, use its axis as the source and project onto the first face.
        target = refs[1].key?('segment') ? 1 : (0 if refs[0].key?('segment'))
        return faces.map { |matches| matches.first.a } unless target

        source = 1 - target
        point = faces[source].filter_map { |anchor| anchor.locate(refs[source]['station']) }.first
        return unless point

        projected = faces[target].filter_map do |anchor|
          t = foot(point, anchor.a, anchor.b)
          anchor.at(t.clamp(0, 1)) if t.between?(-0.000001, 1.000001)
        end.first
        return unless projected

        source.zero? ? [point, projected] : [projected, point]
      end

      def geometry(points, offset)
        a, b = points
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = Math.hypot(dx, dy)
        return if length < 1.0

        normal = [-dy / length, dx / length]
        vector = normal.map { |axis| axis * offset }
        shifted = points.map { |point| point.zip(vector).map { |p, v| p + v } }
        [normal, length, vector, shifted]
      end

      def within_crop?(points, crop)
        !crop || points.all? { |x, y| x.between?(crop[0], crop[2]) && y.between?(crop[1], crop[3]) }
      end

      def draw(entities, model, cut, data, entries, hidden)
        ids = entries.flat_map { |entry| entry.fetch('refs').map { |ref| ref.fetch('id') } }.uniq
        anchors = references(model, cut, hidden, ids: ids)
        entries.to_h do |entry|
          points = endpoints(entry.fetch('refs'), anchors)
          info = geometry(points, entry.fetch('offset')) if points
          value = nil
          if info && within_crop?(points + info.last, data['plan_crop'])
            _, value, vector, = info
            dimension = entities.add_dimension_linear(*points.map { |xy| API.point(*xy, cut - 0.12) },
                                                       Geom::Vector3d.new(vector[0].mm, vector[1].mm, 0))
            raise ArgumentError, '平面に連動寸法を描けませんでした。' unless dimension

            dimension.has_aligned_text = true
            dimension.layer = model.layers[0]
          end
          [entry.fetch('id'), value&.round(1)]
        end
      end
    end
  end
end
