# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module LayerHatches
      API = SbrArchitecture
      ANGLES = { 'diag' => [45], 'reverse' => [-45], 'cross' => [45, -45], 'level' => [0], 'none' => [] }.freeze
      INK = 'SBR｜層ハッチ線'
      PAPER_PITCH_MM = 1.7
      MIN_HATCH_THICKNESS_MM = 0.35
      MEMBER_HATCHES = {
        beam: [%w[beam], 45, '梁断面ハッチ'],
        column: [%w[column], -45, '柱断面ハッチ'],
        foundation: [%w[strip_foundation pad_foundation], 0, '基礎断面ハッチ'],
        roof: [%w[roof], 45, '屋根断面ハッチ'],
        stair: [%w[stair], 45, '階段断面ハッチ']
      }.freeze
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

      def lines(boundary, angle, spacing: 85.0)
        radians = angle * Math::PI / 180
        c, s = Math.cos(radians), Math.sin(radians)
        local = boundary.map do |segment|
          segment.map { |x, y| [x * c + y * s, -x * s + y * c] }
        end
        low, high = local.flat_map { |segment| segment.map(&:last) }.minmax
        spacing = [spacing, (high - low) / 450].max
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

      def hatch_angles(layer, denominator)
        return [] if layer.fetch('thickness').to_f / denominator < MIN_HATCH_THICKNESS_MM

        ANGLES.fetch(layer.fetch('pattern'))
      end

      def clip_lines(strokes, masks)
        strokes.flat_map { |a, b| ColumnCuts.clip(a, b, masks) }
      end

      def draw_hatch(entities, strokes, at, ink)
        strokes.count do |first, last|
          edge = entities.add_line(at.call(first), at.call(last))
          next false unless edge

          edge.material = ink
          true
        end
      end

      def member_cuts(group, items, slice, at, spacing, layer_masks)
        masks = layer_masks.dup
        counts = { member_hatch_lines: 0 }
        MEMBER_HATCHES.each do |kind, (types, angle, name)|
          outlines = items.select { |item| types.include?(Follow.kind(item)) }.filter_map do |item|
            outline = boundary(item, item.transformation, *slice)
            outline unless outline.empty?
          end
          counts[:"#{kind}_cuts"] = outlines.size
          hatch = outlines.flat_map do |outline|
            strokes = clip_lines(lines(outline, angle, spacing: spacing), masks)
            loops = ColumnCuts.closed_loops(outline)
            masks << ColumnCuts.mask_for(loops) unless loops.empty?
            strokes
          end
          next if hatch.empty?

          target = group.entities.add_group
          target.name = name
          counts[:member_hatch_lines] += draw_hatch(target.entities, hatch, at, hatch_ink(group.model))
          target.entities.each { |entity| entity.layer = group.model.layers[0] }
        end
        counts
      end

      def hatch_ink(model)
        ink = model.materials[INK] || model.materials.add(INK)
        ink.color = Sketchup::Color.new(115, 115, 115)
        ink
      end

      def slice(point, eye_direction)
        axis = eye_direction.to_a.each_index.max_by { |i| eye_direction.to_a[i].abs }
        projection = [0, 1, 2] - [axis]
        # Sample just inside the visible side so a cut coinciding with a face
        # or a vertex has the same half-open rule as the viewport.
        coordinate = point.to_a[axis].to_mm - eye_direction.to_a[axis] * 0.03
        [axis, coordinate, projection]
      end

      def populate(group, point, eye_direction, hidden, denominator:, masks: [])
        axis, coordinate, projection = slice(point, eye_direction)
        display = point.to_a[axis].to_mm - eye_direction.to_a[axis] * 0.4
        at = lambda do |xy|
          values = []
          values[axis] = display
          projection.zip(xy).each { |i, value| values[i] = value }
          API.point(*values)
        end
        counts = { cut_layers: 0, hatch_lines: 0, simplified_layers: 0 }
        spacing = PAPER_PITCH_MM * denominator
        hatch_group = nil
        ink = nil
        layer_masks = []
        items = group.model.entities.grep(Sketchup::Group).reject do |item|
          hidden.include?(item.persistent_id) || !item.layer.visible?
        end
        items.each do |item|
          next unless %w[wall slab].include?(Follow.kind(item))

          Composition.each_layer(item) do |part, layer, _, transform|
            next if part.hidden? || !part.layer.visible?

            outline = boundary(part, transform, axis, coordinate, projection)
            next if outline.empty?

            counts[:cut_layers] += 1
            angles = hatch_angles(layer, denominator)
            counts[:simplified_layers] += 1 if angles.empty? && layer.fetch('pattern') != 'none'
            hatch = angles.flat_map { |angle| lines(outline, angle, spacing: spacing) }
            if axis == 2
              clip_lines(outline, masks).each { |a, b| group.entities.add_line(at.call(a), at.call(b)) }
            else
              loops = ColumnCuts.closed_loops(outline)
              layer_masks << ColumnCuts.mask_for(loops) unless loops.empty?
            end
            next if hatch.empty?

            unless hatch_group
              hatch_group = group.entities.add_group
              hatch_group.name = '層ハッチ'
              ink = hatch_ink(group.model)
            end
            counts[:hatch_lines] += draw_hatch(hatch_group.entities, clip_lines(hatch, masks), at, ink)
          end
        end
        counts.merge!(member_cuts(group, items, [axis, coordinate, projection], at, spacing, layer_masks)) if axis != 2
        hatch_group&.entities&.each { |entity| entity.layer = group.model.layers[0] }
        group.entities.each { |entity| entity.layer = group.model.layers[0] }
        counts
      end
    end
  end
end
