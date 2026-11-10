# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module ElevationDatums
      API = SbrArchitecture
      Band = Struct.new(:wall, :index, :outline, :bottom, :top, :facing, :at)
      module_function

      def selected_height(model)
        edge = model.selection.first
        unless model.selection.size == 1 && edge.is_a?(Sketchup::Edge) && edge.valid?
          raise ArgumentError, '軒または棟の水平な辺を1本選択してください。'
        end

        transform = model.edit_transform
        a, b = [edge.start, edge.end].map { |vertex| vertex.position.transform(transform).z.to_mm }
        raise ArgumentError, '選んだ辺は水平ではありません。' if (a - b).abs > 0.1

        ((a + b) / 2.0).round(1)
      end

      def bands(groups, eye, hidden)
        horizontal = Z_AXIS.cross(eye)
        project = lambda do |point|
          vector = point - ORIGIN
          [vector.dot(horizontal).to_mm, vector.dot(eye).to_mm, point.z.to_mm]
        end
        groups.flat_map do |wall|
          next [] unless Follow.kind(wall) == 'wall' && !hidden.include?(wall.persistent_id) && wall.layer.visible?

          transform = wall.transformation
          next [] unless PlanLinework.upright?(transform)

          params = Follow.parameters(wall)
          points = params.fetch('points')
          closed = points.first == points.last
          exterior_left = closed && ColumnCuts.signed_area(points).negative?
          bottom = ORIGIN.transform(transform).z.to_mm
          top = API.point(0, 0, WallHeads.overall_height(params)).transform(transform).z.to_mm
          API.wall_profiles(params).map.with_index do |profile, index|
            outline = profile.map { |x, y| project.call(API.point(x, y).transform(transform)).first(2) }
            positions, local = PlanLinework.basis(params, profile, index)
            left, right = positions.first(2).map(&:last)
            offset = (positions[0][0] + positions[3][0]) / 2.0
            side_depths = [left, right].map { |side| project.call(local.call(offset, side, 0).transform(transform))[1] }
            facing = (side_depths.first - side_depths.last).abs > 1 &&
                     (!closed || (exterior_left ? side_depths.first > side_depths.last : side_depths.last > side_depths.first))
            lateral = side_depths.first > side_depths.last ? left : right
            at = ->(x, z) { project.call(local.call(x, lateral, z).transform(transform)) }
            Band.new(wall, index, outline, bottom, top, facing, at)
          end
        end
      end

      def front_depth(outline, x)
        depths = outline.zip(outline.rotate).flat_map do |(a, b), (c, d)|
          next [] unless x.between?(*[a, c].minmax)
          next [b, d] if (c - a).abs < 0.0001

          [b + (d - b) * (x - a) / (c - a)]
        end
        depths.max
      end

      def visible?(bands, source, x, depth, z)
        bands.none? do |band|
          next false if band.equal?(source) || z < band.bottom || z >= band.top

          other = front_depth(band.outline, x)
          other && other > depth + 1.0
        end
      end

      def openings(groups, eye, hidden)
        walls = bands(groups, eye, hidden)
        walls.group_by(&:wall).flat_map do |wall, segments|
          Follow.parameters(wall).fetch('openings', []).flat_map do |opening|
            mark = opening['mark'].to_s.strip
            host = segments[opening.fetch('segment')]
            next [] if mark.empty? || !host&.facing

            _, _, bottom, top = Openings.position(opening)
            center = opening.fetch('offset')
            x, depth, z = host.at.call(center, (bottom + top) / 2.0)
            next [] unless visible?(walls, host, x, depth, z)

            result = [[mark, '上端', host.at.call(center, top).last.round(1)]]
            result << [mark, '下端', host.at.call(center, bottom).last.round(1)] if opening['kind'] == 'window'
            result
          end
        end
      end

      def labels(openings, data)
        rows = openings.group_by { |_, role, z| [role, z] }.map do |(role, z), entries|
          marks = entries.map(&:first).uniq.sort
          name = marks.one? ? marks.first : "#{marks.first} ほか#{marks.size - 1}件"
          ["#{name} #{role}", z]
        end
        { 'eave' => '軒高', 'ridge' => '棟高', 'roof_high' => '屋根最高' }.each do |key, label|
          rows << [label, data.fetch(key)] if data.key?(key)
        end
        rows
      end

      def draw(entities, rows, box, eye, denominator:)
        horizontal = Z_AXIS.cross(eye)
        corners = 8.times.map { |index| box.corner(index) }
        left = corners.map { |point| (point - ORIGIN).dot(horizontal).to_mm }.min
        depth = corners.map { |point| (point - ORIGIN).dot(eye).to_mm }.max + 1
        at = lambda do |x, z|
          API.point(x * horizontal.x + depth * eye.x, x * horizontal.y + depth * eye.y, z)
        end
        previous = -Float::INFINITY
        rows.sort_by { |name, z| [z, name] }.each do |name, z|
          label_z = [z, previous + DrawingDatums::LEVEL_LABEL_GAP_MM * denominator].max
          previous = label_z
          anchor = left - 3 * denominator
          elbow = left - 8 * denominator
          finish = left - 13 * denominator
          entities.add_line(at.call(anchor, z), at.call(elbow, z))
          entities.add_line(at.call(elbow, z), at.call(finish, label_z))
          text = "#{name}  #{z.zero? ? '±0' : format('%+.10g', z)}"
          # Leave room for the exported text before the sloped part of the leader.
          width = text.each_char.sum { |character| character.ascii_only? ? 2.4 : 4.2 }
          text_x = finish - (width + 3) * denominator
          entities.add_line(at.call(text_x, label_z), at.call(finish, label_z))
          entities.add_text(text, at.call(text_x, label_z + 3.5 * denominator))
        end
        rows.size
      end
    end
  end
end
