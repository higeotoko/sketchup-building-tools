# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module FramingPlan
      API = SbrArchitecture
      module_function

      def select_beams(groups, datum, tolerance, hidden)
        groups.select do |group|
          next unless Follow.kind(group) == 'beam' && !hidden.include?(group.persistent_id) && group.layer.visible?

          box = group.bounds
          box.valid? && (box.max.z.to_mm - datum).abs <= tolerance + 0.001
        end
      end

      def bounds(beams)
        box = Geom::BoundingBox.new
        beams.each { |beam| box.add(beam.bounds.min, beam.bounds.max) }
        box if box.valid?
      end

      def hull(points)
        ordered = points.uniq.sort
        [ordered, ordered.reverse].flat_map do |sequence|
          side = []
          sequence.each do |point|
            while side.size >= 2
              a, b = side.last(2)
              break if (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0]) > 0.001

              side.pop
            end
            side << point
          end
          side[0...-1]
        end
      end

      def footprint(beam, params)
        local = if params['system'] == 'steel'
                  member = API.steel_member('beam', params)
                  API.steel_section_ends(member).flatten(2)
                else
                  API.member_profile('beam', params).map { |x, y| API.point(x, y) }
                end
        points = local.map do |point|
          point.transform(beam.transformation).to_a.first(2).map { |value| value.to_mm.round(3) }
        end
        hull(points)
      end

      def section_label(params)
        params['section_id'] || params.values_at('width', 'depth').map { |mm| format('%g', mm) }.join('×')
      end

      def draw(group, beams, level, datum, hidden)
        entities = group.entities
        labels = []
        columns = []
        masks = []
        if beams.any?
          underside = beams.map { |beam| beam.bounds.min.z.to_mm }.min - 1.0
          columns = ColumnCuts.sections(group.model, underside, hidden)
          masks = ColumnCuts.masks(columns)
          beams.each do |beam|
            params = Follow.parameters(beam)
            outline = footprint(beam, params)
            next if outline.size < 3

            outline.zip(outline.rotate).each do |a, b|
              ColumnCuts.clip(a, b, masks).each do |first, last|
                entities.add_line(API.point(*first, datum - 0.5), API.point(*last, datum - 0.5))
              end
            end
            axis = [[0, 0], params.fetch('end')].map do |x, y|
              API.point(x, y).transform(beam.transformation).to_a.first(2).map(&:to_mm)
            end
            labels << [section_label(params), axis, outline]
          end
          ColumnCuts.draw(entities, columns, datum)
        end
        grids = PlanLinework.grids(group.model, entities, level, datum, hidden)
        entities.each { |entity| entity.layer = group.model.layers[0] }
        label_masks = masks + labels.map { |_, _, outline| ColumnCuts.mask_for([outline]) }
        [{ beam_members: labels.size, column_cuts: columns.size, grids: grids.size }, grids, labels, label_masks]
      end

      def draw_labels(entities, labels, datum, denominator, masks)
        used = masks.dup
        labels.count do |text, ((x1, y1), (x2, y2)), outline|
          length = Math.hypot(x2 - x1, y2 - y1)
          next false if length < Layout::MIN_MM

          nx, ny = -(y2 - y1) / length, (x2 - x1) / length
          mx, my = (x1 + x2) / 2.0, (y1 + y2) / 2.0
          low, high = outline.map { |x, y| (x - mx) * nx + (y - my) * ny }.minmax
          width = text.each_char.sum { |char| char.ascii_only? ? 2.1 : 3.6 } * denominator
          height = 3.8 * denominator
          gap = (1.5 * denominator) + (nx.abs * width + ny.abs * height) / 2.0
          [0, -0.2, 0.2].product([high + gap, low - gap]).any? do |along, offset|
            x = mx + (x2 - x1) * along + nx * offset - width / 2.0
            y = my + (y2 - y1) * along + ny * offset - height / 2.0
            corners = [[x, y], [x + width, y], [x + width, y + height], [x, y + height]]
            area = ColumnCuts.mask_for([corners])
            next false if used.any? { |mask| overlaps_label?(area, mask) }

            mark = entities.add_text(text, API.point(x, y, datum - 0.25))
            mark.font = { size: 9 } if mark.respond_to?(:font=)
            used << area
            true
          end
        end
      end

      def overlaps_label?(label, mask)
        (corners, ax, ay), (loops, bx, by) = label, mask
        return false unless ax.first < bx.last && bx.first < ax.last && ay.first < by.last && by.first < ay.last

        corners = corners.first
        outline = loops.first
        corners.any? { |point| ColumnCuts.contains?(outline, point) } ||
          outline.any? { |x, y| x.between?(*ax) && y.between?(*ay) } ||
          corners.zip(corners.rotate).any? { |a, b| ColumnCuts.intersects?(a, b, [mask]) }
      end
    end
  end
end
