# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module ColumnCuts
      API = SbrArchitecture
      TOLERANCE = 0.001
      module_function

      def sections(model, cut, hidden)
        model.entities.grep(Sketchup::Group).filter_map do |column|
          next unless Follow.kind(column) == 'column' && !hidden.include?(column.persistent_id) && column.layer.visible?

          box = column.bounds
          next unless box.valid? && box.min.z.to_mm < cut && cut <= box.max.z.to_mm

          edges = LayerHatches.boundary(column, column.transformation, 2, cut - 0.03, [0, 1])
          loops = closed_loops(edges)
          next if loops.empty?

          [loops.max_by { |loop| signed_area(loop).abs }, loops, edges]
        end
      end

      def closed_loops(edges)
        links = Hash.new { |hash, key| hash[key] = [] }
        edges.each do |a, b|
          a, b = [a, b].map { |point| point.map { |value| value.round(3) } }
          next if a == b || links[a].include?(b)

          links[a] << b
          links[b] << a
        end
        return [] unless links.values.all? { |neighbors| neighbors.size == 2 }

        result = []
        until links.empty?
          start = links.keys.first
          previous = start
          current = links.delete(start).first
          path = [start]
          until current == start
            path << current
            next_point = links.delete(current).find { |neighbor| neighbor != previous }
            previous, current = current, next_point
          end
          result << path if path.size >= 3 && signed_area(path).abs >= TOLERANCE
        end
        result
      end

      def signed_area(loop)
        # Shift the origin before multiplying to retain precision for geolocated models.
        x0, y0 = loop.first
        loop.zip(loop.rotate).sum { |(x, y), (u, v)| (x - x0) * (v - y0) - (u - x0) * (y - y0) } / 2.0
      end

      def masks(sections)
        sections.map { |outline, _, _| mask_for([outline]) }
      end

      def intersects?(a, b, masks)
        length = Math.hypot(a[0] - b[0], a[1] - b[1])
        visible = clip(a, b, masks).sum { |first, last| Math.hypot(first[0] - last[0], first[1] - last[1]) }
        length - visible > TOLERANCE
      end

      def mask_for(loops)
        xs, ys = loops.flatten(1).transpose
        [loops, xs.minmax, ys.minmax]
      end

      def clip(a, b, masks)
        return [[a, b]] if masks.empty?

        ax, ay = a
        bx, by = b
        span_x, span_y = [ax, bx].minmax, [ay, by].minmax
        relevant = masks.select do |_, x, y|
          span_x[0] <= x[1] && span_x[1] >= x[0] && span_y[0] <= y[1] && span_y[1] >= y[0]
        end
        return [[a, b]] if relevant.empty?

        dx, dy = bx - ax, by - ay
        parameters = [0.0, 1.0]
        relevant.flat_map(&:first).each do |outline|
          outline.zip(outline.rotate).each do |(x, y), (u, v)|
            ex, ey = u - x, v - y
            denominator = dx * ey - dy * ex
            next if denominator.abs < 1e-9

            rx, ry = x - ax, y - ay
            t = (rx * ey - ry * ex) / denominator
            s = (rx * dy - ry * dx) / denominator
            parameters << t if t.between?(0, 1) && s.between?(0, 1)
          end
        end
        at = ->(t) { [ax + t * dx, ay + t * dy] }
        length = Math.hypot(dx, dy)
        parameters.sort.uniq.each_cons(2).filter_map do |first, last|
          next if (last - first) * length < TOLERANCE

          center = at.call((first + last) / 2)
          next if relevant.any? { |loops, _, _| loops.count { |outline| contains?(outline, center) }.odd? }

          [at.call(first), at.call(last)]
        end
      end

      def contains?(outline, point)
        x, y = point
        outline.zip(outline.rotate).count do |(ax, ay), (bx, by)|
          (ay > y) != (by > y) && x < ax + (bx - ax) * (y - ay) / (by - ay)
        end.odd?
      end

      def draw(entities, sections, cut)
        sections.each do |outline, loops, edges|
          group = entities.add_group
          untagged = group.model.layers[0]
          group.layer = untagged
          at = ->(xy) { API.point(*xy, cut - 0.12) }
          # White faces mask projected lines within the footprint. The true
          # inner contour and the hatch preserve the bore of a hollow section.
          face = group.entities.add_face(outline.map { |xy| at.call(xy) })
          face.reverse! if face && face.normal.z.negative?
          loops.each do |loop|
            loop.zip(loop.rotate).each { |a, b| group.entities.add_line(at.call(a), at.call(b)) }
          end
          LayerHatches.lines(edges, 45, spacing: 10).each { |a, b| group.entities.add_line(at.call(a), at.call(b)) }
          group.entities.each { |entity| entity.layer = untagged }
        end
      end
    end
  end
end
