# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module LayerHatches
      API = SbrArchitecture
      ANGLES = { 'diag' => [45], 'reverse' => [-45], 'cross' => [45, -45], 'level' => [0], 'none' => [] }.freeze
      module_function

      def crossing(a, b, axis, coordinate, projection)
        da, db = a[axis] - coordinate, b[axis] - coordinate
        return if da.negative? == db.negative?

        ratio = da / (da - db)
        projection.map { |i| a[i] + (b[i] - a[i]) * ratio }
      end

      def boundary(group, transform, axis, coordinate, projection)
        group.entities.grep(Sketchup::Face).flat_map do |face|
          cuts = face.loops.flat_map do |loop|
            vertices = loop.vertices.map { |vertex| vertex.position.transform(transform).to_a.map(&:to_mm) }
            (vertices + [vertices.first]).each_cons(2).filter_map do |a, b|
              crossing(a, b, axis, coordinate, projection)
            end
          end
          next [] if cuts.size < 2

          dimension = (0..1).max_by do |i|
            low, high = cuts.map { |point| point[i] }.minmax
            high - low
          end
          cuts.sort_by { |point| point[dimension] }.each_slice(2).filter_map do |a, b|
            [a, b] if b && Math.hypot(a[0] - b[0], a[1] - b[1]) >= 0.01
          end
        end
      end

      def lines(boundary, angle)
        radians = angle * Math::PI / 180
        c, s = Math.cos(radians), Math.sin(radians)
        local = boundary.map do |segment|
          segment.map { |x, y| [x * c + y * s, -x * s + y * c] }
        end
        low, high = local.flat_map { |segment| segment.map(&:last) }.minmax
        spacing = [85.0, (high - low) / 450].max
        ((low / spacing).ceil..(high / spacing).floor).flat_map do |index|
          y = index * spacing
          hits = local.filter_map do |a, b|
            crossing(a, b, 1, y, [0])&.first
          end
          hits.sort.each_slice(2).filter_map do |a, b|
            next unless b && b - a >= 0.05

            [[a * c - y * s, a * s + y * c], [b * c - y * s, b * s + y * c]]
          end
        end
      end

      def populate(group, point, eye_direction, hidden)
        axis = eye_direction.to_a.each_index.max_by { |i| eye_direction.to_a[i].abs }
        projection = [0, 1, 2] - [axis]
        # Sample just inside the visible side so a cut coinciding with a face
        # or a vertex has the same half-open rule as the viewport.
        coordinate = point.to_a[axis].to_mm - eye_direction.to_a[axis] * 0.03
        display = point.to_a[axis].to_mm - eye_direction.to_a[axis] * 0.4
        at = lambda do |xy|
          values = []
          values[axis] = display
          projection.zip(xy).each { |i, value| values[i] = value }
          API.point(*values)
        end
        counts = { cut_layers: 0, hatch_lines: 0 }
        group.model.entities.grep(Sketchup::Group).each do |item|
          next unless %w[wall slab].include?(Follow.kind(item)) && !hidden.include?(item.persistent_id) && item.layer.visible?

          Composition.each_layer(item) do |part, layer, _, transform|
            next if part.hidden? || !part.layer.visible?

            outline = boundary(part, transform, axis, coordinate, projection)
            next if outline.empty?

            counts[:cut_layers] += 1
            hatch = ANGLES.fetch(layer.fetch('pattern')).flat_map { |angle| lines(outline, angle) }
            counts[:hatch_lines] += hatch.size
            (outline + hatch).each { |a, b| group.entities.add_line(at.call(a), at.call(b)) }
          end
        end
        group.entities.each { |entity| entity.layer = group.model.layers[0] }
        counts
      end
    end
  end
end
