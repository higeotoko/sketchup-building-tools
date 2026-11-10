# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module DrawingDatums
      API = SbrArchitecture
      LEVEL_LABEL_GAP_MM = 6.5
      SECTION_END_MM = 4.0
      SECTION_GAP_MM = 1.5
      SECTION_STROKES_MM = [8.0, 1.2, 1.2].freeze
      SECTION_INK = 'SBR｜断面位置線'
      module_function

      def section_line_spans(first, last, denominator)
        end_length = SECTION_END_MM * denominator
        return [[first, last]] if last - first <= 2 * end_length

        gap = SECTION_GAP_MM * denominator
        limit = last - end_length - gap
        start = first + end_length + gap
        spans = [[first, first + end_length]]
        SECTION_STROKES_MM.cycle do |paper_length|
          break if start >= limit

          finish = [start + paper_length * denominator, limit].min
          spans << [start, finish] if finish - start >= 0.5 * denominator
          start = finish + gap
        end
        spans << [last - end_length, last]
      end

      def section_axis(item)
        item.fetch('side').start_with?('x') ? 0 : 1
      end

      def sections_in_plan(sections, box)
        low = box.min.to_a.map(&:to_mm)
        high = box.max.to_a.map(&:to_mm)
        sections.select do |item|
          axis = section_axis(item)
          item.fetch('offset').between?(low[axis], high[axis])
        end
      end

      def dimension_masks(annotation, denominator)
        margin = 2.8 * denominator
        groups = [[annotation.entities, IDENTITY]]
        groups.concat(annotation.entities.grep(Sketchup::Group).map { |group| [group.entities, group.transformation] })
        groups.flat_map do |entities, transform|
          entities.grep(Sketchup::DimensionLinear).map do |dim|
            ends = [dim.start.last, dim.end.last].map do |point|
              (point + dim.offset_vector).transform(transform).to_a.first(2).map(&:to_mm)
            end
            x, y = ends.transpose.map { |values| a, b = values.minmax; [a - margin, b + margin] }
            ColumnCuts.mask_for([[[x.first, y.first], [x.last, y.first], [x.last, y.last], [x.first, y.last]]])
          end
        end
      end

      def section_marks(entities, sections, frame, cut, denominator:, masks: [], grid_masks: [])
        z = cut - 0.25
        frame_low = frame.min.to_a.map(&:to_mm)
        frame_high = frame.max.to_a.map(&:to_mm)
        sections.each do |item|
          x_cut = section_axis(item).zero?
          transverse = x_cut ? 1 : 0
          at = item.fetch('offset')
          toward = item.fetch('side').end_with?('+') ? -1 : 1
          xy = ->(a, b) { x_cut ? [a, b] : [b, a] }
          point = ->(a, b) { API.point(*xy.call(a, b), z) }
          label = "#{item.fetch('name')} / #{item.fetch('sheet')}"
          # On the left, the text reads toward the dimension chains. Dimension
          # labels extend past the line bounds, so reserve clearance for both.
          label_width = label.each_char.sum { |character| character.ascii_only? ? 2.35 : 4.2 }
          low_gap = x_cut ? 1050 : (label_width + 18) * denominator
          high_gap = [300, (x_cut ? 4 : 8) * denominator].max
          ends = [frame_low[transverse] - low_gap, frame_high[transverse] + high_gap]
          ends = ends.zip([-1, 1]).map do |end_at, side|
            clearance = 6 * denominator
            grid_masks.reduce(end_at) do |position, (_, x, y)|
              along, across = x_cut ? [y, x] : [x, y]
              next position unless at.between?(across.first - clearance, across.last + clearance) &&
                                   position.between?(along.first - clearance, along.last + clearance)

              side.negative? ? along.first - clearance : along.last + clearance
            end
          end
          materials = entities.model.materials
          ink = materials[SECTION_INK] || materials.add(SECTION_INK)
          color = Sketchup::Color.new(64, 64, 64)
          ink.color = color unless ink.color == color
          section_line_spans(*ends, denominator).each do |first, last|
            ColumnCuts.clip(xy.call(at, first), xy.call(at, last), masks + grid_masks).each do |a, b|
              next if Math.hypot(a[0] - b[0], a[1] - b[1]) < 0.5 * denominator

              edge = entities.add_line(API.point(*a, z), API.point(*b, z))
              edge.material = ink if edge
            end
          end
          ends.zip([-1, 1]).each do |end_at, side|
            tip = point.call(at + toward * 5.5 * denominator, end_at)
            entities.add_line(point.call(at, end_at), tip)
            [-1.35, 1.35].each do |flank|
              entities.add_line(tip, point.call(at + toward * 3.2 * denominator, end_at + flank * denominator))
            end
            label_offset = x_cut ? side * [140, 3.5 * denominator].max : 4 * denominator
            label_at = x_cut ? at : at + 4 * denominator
            entities.add_text(label, point.call(label_at, end_at + label_offset))
          end
        end
        sections.size
      end

      def beam_clearance(beam, floor, point, eye)
        return unless floor && beam.is_a?(Sketchup::Group) && Follow.kind(beam) == 'beam'

        axis, coordinate, projection = LayerHatches.slice(point, eye)
        boundary = LayerHatches.boundary(beam, beam.transformation, axis, coordinate, projection)
        vertices = boundary.flatten(1)
        return if vertices.empty?

        bottom = vertices.map(&:last).min
        return if bottom - floor < 0.1

        horizontal = Z_AXIS.cross(eye)
        sign = horizontal.to_a.fetch(projection.first)
        left, right = vertices.select { |_, z| (z - bottom).abs < 0.001 }.map { |x, _| x * sign }.minmax
        [left, right, floor, bottom]
      end

      def clearance_mark(entities, clearance, level, box, eye, point, denominator:)
        left, right, floor, bottom = clearance
        horizontal = Z_AXIS.cross(eye)
        depth = (point - ORIGIN).dot(eye).to_mm - 1.0
        at = lambda do |x, z|
          API.point(x * horizontal.x + depth * eye.x, x * horizontal.y + depth * eye.y, z)
        end
        outer_left, outer_right = 8.times.map { |i| (box.corner(i) - ORIGIN).dot(horizontal).to_mm }.minmax
        height = format('%g', (bottom - floor).round(1))
        labels = ["梁下 #{height} mm", "#{level} 基準"]
        paper_width = ->(lines) { lines.map { |text| text.each_char.sum { |c| c.ascii_only? ? 2.8 : 4.3 } }.max }
        left_room, right_room = [left - outer_left, outer_right - right].map { |space| space / denominator }
        labels = ['梁下', "#{height} mm", "#{level} 基準"] if [left_room, right_room].max < paper_width.call(labels) + 9
        width = paper_width.call(labels)
        place_right = right_room >= width + 9
        edge, direction = place_right ? [right, 1] : [left, -1]
        line = edge + direction * 6 * denominator
        line = outer_left - 5 * denominator if !place_right && left_room < width + 9
        tick = 1.3 * denominator
        entities.add_line(at.call(line, floor), at.call(line, bottom))
        entities.add_line(at.call(edge, bottom), at.call(line + direction * tick, bottom))
        entities.add_line(at.call(line - tick, floor), at.call(line + tick, floor))
        text_x = place_right ? line + 2 * denominator : line - (width + 2) * denominator
        mid = (floor + bottom) / 2.0
        labels.each_with_index do |label, index|
          offset = ((labels.size - 1) / 2.0 - index) * 5 * denominator
          entities.add_text(label, at.call(text_x, mid + offset))
        end
      end

      def levels(entities, levels, box, eye, cut_point, denominator:, storey_dimensions: false)
        horizontal = Z_AXIS.cross(eye)
        corners = 8.times.map { |index| box.corner(index) }
        right = corners.map { |p| (p - ORIGIN).dot(horizontal) }.max.to_mm
        depth = if cut_point
                  (cut_point - ORIGIN).dot(eye).to_mm - 1.0
                else
                  corners.map { |p| (p - ORIGIN).dot(eye) }.max.to_mm + 1.0
                end
        at = lambda do |x, z|
          API.point(x * horizontal.x + depth * eye.x, x * horizontal.y + depth * eye.y, z)
        end
        shown = levels.select { |_, z| z.between?(box.min.z.to_mm - 1000, box.max.z.to_mm + 1000) }.sort_by(&:last)
        left = right + 180
        gap = LEVEL_LABEL_GAP_MM * denominator
        previous = -Float::INFINITY
        shown.each do |name, z|
          label_z = [z, previous + gap].max
          previous = label_z
          entities.add_line(at.call(left + 70, z - 65), at.call(left + 70, z + 65))
          if label_z == z
            entities.add_line(at.call(left, z), at.call(left + 470, z))
          else
            entities.add_line(at.call(left, z), at.call(left + 210, z))
            entities.add_line(at.call(left + 210, z), at.call(left + 350, label_z))
            entities.add_line(at.call(left + 350, label_z), at.call(left + 470, label_z))
          end
          label = z.zero? ? '±0' : format('%+.10g', z)
          entities.add_text("#{name}  #{label}", at.call(left + 540, label_z + 70))
        end
        count = if storey_dimensions
                  span = shown.map do |name, z|
                    "#{name}  #{format('%+.10g', z)}".each_char.sum { |char| char.ascii_only? ? 2.4 : 4.2 }
                  end.max || 0
                  start = left + 540 + (span + 4) * denominator
                  offset = 6 * denominator
                  vector = Geom::Vector3d.new(horizontal.x * offset.mm, horizontal.y * offset.mm, 0)
                  storeys = shown.reject { |name, _| name.casecmp?('GL') }.map(&:last).uniq
                  storeys.each_cons(2).count do |low, high|
                    dim = entities.add_dimension_linear(at.call(start, low), at.call(start, high), vector)
                    dim.has_aligned_text = true
                    dim.text = "階高 #{format('%g', (high - low).round(1))}"
                    true
                  end
                else
                  0
                end
        [shown.size, count]
      end
    end
  end
end
