# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module PlanLinework
      API = SbrArchitecture
      module_function

      def upright?(transform)
        vector = API.point(0, 0, 1).transform(transform) - ORIGIN.transform(transform)
        vector.z.positive? && vector.parallel?(Z_AXIS)
      end

      def basis(params, profile, index)
        origin, axis = Openings.segment(params.fetch('points'), index)
        left = [-axis[1], axis[0]]
        projection = profile.map { |point| [Openings.projection(point, origin, axis), Openings.projection(point, origin, left)] }
        at = lambda do |offset, lateral, z|
          API.point(origin[0] + axis[0] * offset + left[0] * lateral,
                    origin[1] + axis[1] * offset + left[1] * lateral, z)
        end
        [projection, at]
      end

      def slices(params, z)
        return [] unless z >= 0 && z < WallHeads.overall_height(params)

        profiles = API.wall_profiles(params)
        if z < params.fetch('height')
          by_segment = Openings.validate(params, profiles)
        else
          _, _, from, to = Composition.bands(params).fetch(WallHeads.exterior_index(params))
          profiles = profiles.map { |profile| Composition.wall_profile(profile, from, to, params.fetch('thickness')) }
          by_segment = {}
        end
        profiles.each_with_index.map do |profile, index|
          corners, at = basis(params, profile, index)
          a, b, c, d = corners
          openings = by_segment.fetch(index, []).filter_map do |opening|
            x1, x2, bottom, top = Openings.position(opening)
            [x1, x2, opening] if bottom <= z && z < top
          end.sort_by(&:first)
          starts = [[a[0], b[0]], *openings.map { |_, x2, _| [x2, x2] }]
          ends = [*openings.map { |x1, _, _| [x1, x1] }, [d[0], c[0]]]
          rectangles = starts.zip(ends).map do |(left_start, right_start), (left_end, right_end)|
            [at.call(left_start, a[1], z), at.call(right_start, b[1], z),
             at.call(right_end, b[1], z), at.call(left_end, a[1], z)]
          end
          if (planes = Roof.roof_planes(params))
            rectangles = rectangles.filter_map do |rectangle|
              loop = rectangle.map { |point| [point.x.to_mm, point.y.to_mm] }
              planes.each { |plane| loop = Roof.clip_profile(loop) { |xy| Roof.plane_height(plane, xy) - z } }
              loop.map { |xy| API.point(*xy, z) } if loop.size >= 3
            end
          end
          [rectangles, openings, at, a[1], b[1]]
        end
      end

      def point_key(point)
        point.to_a.map { |length| length.to_mm.round(4) }
      end

      def walls(model, entities, cut_height, hidden, extent, masks, hollow_masks:, dimension_openings:)
        result = { wall_edges: 0, opening_marks: 0, skipped_walls: 0, door_swings: 0, opening_dimensions: 0 }
        projections = []
        model.entities.grep(Sketchup::Group).each do |wall|
          next unless Follow.kind(wall) == 'wall' && !hidden.include?(wall.persistent_id) && wall.layer.visible?

          transform = wall.transformation
          if !upright?(transform)
            result[:skipped_walls] += 1
            next
          end
          local_z = API.point(0, 0, cut_height).transform(transform.inverse).z.to_mm
          edges = {}
          overlaps_hollow = false
          project = lambda do |p|
            world = p.transform(transform)
            Geom::Point3d.new(world.x, world.y, (cut_height - 0.5).mm)
          end
          params = Follow.parameters(wall)
          points = params.fetch('points')
          exterior = Layout.wall_outside(params)
          exterior ||= Layout.outside_side(points) if points.first == points.last
          slices(params, local_z).each do |loops, openings, at, left, right|
            loops.each do |loop|
              outline = loop.map { |p| project.call(p) }
              extent.add(outline)
              (outline + [outline.first]).each_cons(2) do |a, b|
                key = [point_key(a), point_key(b)].sort
                if !overlaps_hollow && !hollow_masks.empty?
                  overlaps_hollow = ColumnCuts.intersects?(key[0].first(2), key[1].first(2), hollow_masks)
                end
                edges.key?(key) ? edges.delete(key) : edges[key] = [a, b]
              end
            end
            openings.each do |x1, x2, opening|
              swing = draw_opening(entities, opening, x1, x2, left, right, local_z, at, project, points, outside: exterior)
              result[:door_swings] += 1 if swing
              result[:opening_marks] += 1
            end
            if dimension_openings
              result[:opening_dimensions] += opening_dimensions(entities, openings, exterior, left, right, local_z, at, project)
            end
          end
          edges.each_value do |a, b|
            ends = [a, b].map { |point| point.to_a.first(2).map(&:to_mm) }
            ColumnCuts.clip(*ends, masks).each do |first, last|
              entities.add_line(API.point(*first, cut_height - 0.5), API.point(*last, cut_height - 0.5))
            end
          end
          projections << wall if overlaps_hollow
          result[:wall_edges] += edges.size
        end
        [result, projections]
      end

      def overall_dimensions(entities, extent, aligned: false)
        return 0 unless extent.valid?

        low, high = extent.min, extent.max
        return 0 if high.x - low.x < 1.mm || high.y - low.y < 1.mm

        # Put the overall chain outside the grid spans and any plan annotations.
        annotation_bounds = Geom::BoundingBox.new
        entities.each do |entity|
          box = entity.bounds
          annotation_bounds.add(box.min, box.max) if box.valid?
        end
        a = Geom::Point3d.new(low.x, low.y, low.z)
        x_offset = [annotation_bounds.min.x - low.x, 0].min - 400.mm
        y_offset = [annotation_bounds.min.y - low.y, 0].min - 400.mm
        entities.add_dimension_linear(a, Geom::Point3d.new(high.x, low.y, low.z), Geom::Vector3d.new(0, y_offset, 0))
        vertical = entities.add_dimension_linear(a, Geom::Point3d.new(low.x, high.y, low.z), Geom::Vector3d.new(x_offset, 0, 0))
        vertical.has_aligned_text = true if aligned
        2
      end

      def draw_opening(entities, opening, x1, x2, left, right, z, at, project, points, outside: nil)
        swing = Openings.door_swing(opening)
        Openings.symbol_paths(opening, left, right, points, outside: outside).each do |path|
          vertices = path.map { |x, lateral| project.call(at.call(x, lateral, z)) }
          vertices.size == 2 ? entities.add_line(*vertices) : entities.add_curve(vertices)
        end
        mark = opening['mark'].to_s
        window = opening['kind'] == 'window'
        mark = Openings.label(opening) if mark.empty?
        outward_left = window ? Openings.window_exterior(opening, points, outside: outside) == 'left' : Doors.side(opening) == 'left'
        label_side = outward_left ? right - 300 : left + 300
        entities.add_text(mark, project.call(at.call((x1 + x2) / 2, label_side, z)))
        swing
      end

      def opening_dimensions(entities, openings, exterior, left, right, z, at, project)
        marked = openings.reject { |_, _, opening| opening['mark'].to_s.strip.empty? }
        return 0 if marked.empty?

        swing = marked.filter_map { |_, _, opening| Openings.door_swing(opening) }.first
        side = exterior || (swing&.last == 'left' ? 'right' : 'left')
        face, outward = side == 'left' ? [left, 1] : [right, -1]
        gap = exterior ? 1080 : 730
        # Keep extension lines clear of the opening mark close to the jamb.
        reference = ->(offset) { project.call(at.call(offset, face + outward * 450, z)) }
        offset = project.call(at.call(0, face + outward * gap, z)) - reference.call(0)
        stations = [0, *marked.flat_map { |x1, x2, _| [x1, x2] }]
        unit = LayoutSheets.millimeter_dimensions?(entities.model) ? '' : ' mm'
        stations.each_cons(2).count do |first, last|
          a, b = reference.call(first), reference.call(last)
          distance = a.distance(b).to_mm
          next false if distance < Layout::MIN_MM

          dimension = entities.add_dimension_linear(a, b, offset)
          dimension.text = "#{format('%g', distance.round(1))}#{unit}"
          true
        end
      end

      def omit_coincident_axes(grid, sections)
        return if sections.empty?

        positions = sections.group_by { |spec| DrawingDatums.section_axis(spec) }
        transform = grid.transformation
        strokes = grid.entities.grep(Sketchup::Edge).select do |edge|
          points = edge.vertices.map { |vertex| vertex.position.transform(transform).to_a.first(2).map(&:to_mm) }
          positions.any? do |axis, cuts|
            cuts.any? { |spec| points.all? { |point| (point[axis] - spec.fetch('offset')).abs < 0.01 } }
          end
        end
        grid.entities.erase_entities(strokes) unless strokes.empty?
      end

      def grids(model, entities, level, cut_height, hidden, aligned: false, sections: [], dimensions: true)
        candidates = model.entities.grep(Sketchup::Group).filter_map do |grid|
          next unless Follow.kind(grid) == 'grid' && !hidden.include?(grid.persistent_id) &&
                      grid.layer.visible? && upright?(grid.transformation)

          [grid, Follow.parameters(grid)]
        end
        matching = candidates.select { |_, params| !params['level'] || params['level'] == level }
        matching = candidates if matching.empty? && candidates.one?
        matching.map do |grid, params|
          copy = entities.add_group
          copy.name = grid.name
          copy.layer = model.layers[0]
          API.write_grid(copy, params, labels: false, dimensions: dimensions)
          if aligned
            copy.entities.grep(Sketchup::DimensionLinear).each do |dimension|
              direction = dimension.end.last - dimension.start.last
              dimension.has_aligned_text = true if direction.parallel?(Y_AXIS)
            end
          end
          z = (cut_height - 0.5).mm - grid.transformation.origin.z
          copy.transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z)) * grid.transformation
          omit_coincident_axes(copy, sections)
          [copy.transformation, params]
        end
      end

      def grid_bubbles(group, grids, frame, denominator, dimension_masks, sections)
        return [] if grids.empty?

        entities = group.entities
        corners = (0...4).map { |index| frame.corner(index) }
        dimension_masks.each do |loops, _, _|
          corners.concat(loops.first.map { |x, y| API.point(x, y) })
        end
        stems = []
        placed = []
        masks = grids.flat_map do |transform, params|
          xs, ys = %w[x_spans y_spans].map { |key| Layout.stations(params.fetch(key)) }
          widths = (params.fetch('x_names') + params.fetch('y_names')).to_h do |name|
            [name, name.each_char.sum { |character| character.ascii_only? ? 2.35 : 4.2 }]
          end
          radius = [3.8, widths.values.max / 2.0 + 1.4].max * denominator
          [[xs, ys, 'x_names'], [ys, xs, 'y_names']].flat_map do |stations, cross, key|
            at = lambda do |fixed, along|
              coordinates = key == 'x_names' ? [fixed, along] : [along, fixed]
              API.point(*coordinates).transform(transform)
            end
            direction = (at.call(0, 1) - at.call(0, 0)).normalize
            limits = corners.map { |point| (point - ORIGIN).dot(direction).to_mm }.minmax
            stations.zip(params.fetch(key)).flat_map do |station, name|
              [[-360, -1, limits.first], [cross.last + 360, 1, limits.last]].map do |along, sign, limit|
                start = at.call(station, along)
                outward = sign.negative? ? direction.reverse : direction
                distance = sign * (limit - (start - ORIGIN).dot(direction).to_mm)
                center = start.offset(outward, (distance + radius + 2.2 * denominator).mm)
                # Stagger close axes, for example half-module grids at 1:100.
                while placed.any? { |other, size| center.distance(other).to_mm < radius + size + denominator }
                  center = center.offset(outward, (2 * radius + denominator).mm)
                end
                placed << [center, radius]
                rim = center.offset(outward.reverse, radius.mm)
                stems << [start, rim]
                entities.add_circle(center, Z_AXIS, radius.mm, 32)
                x, y, z = center.to_a.map(&:to_mm)
                label = entities.add_text(name, API.point(x - widths.fetch(name) * denominator / 2.0,
                                                           y - 1.7 * denominator, z))
                label.font = { size: 10 } if label.respond_to?(:font=)
                padding = radius + 0.6 * denominator
                ColumnCuts.mask_for([[[x - padding, y - padding], [x + padding, y - padding],
                                      [x + padding, y + padding], [x - padding, y + padding]]])
              end
            end
          end
        end
        entities.each { |entity| entity.layer = group.model.layers[0] }
        keep_clear = dimension_masks + masks
        edges = stems.flat_map { |start, rim| grid_stem(entities, start, rim, keep_clear, sections) }
        GridStyle.apply(group, edges)
        masks
      end

      def grid_stem(entities, start, rim, masks, sections)
        a, b = [start, rim].map { |point| point.to_a.first(2).map(&:to_mm) }
        return [] if sections.any? do |section|
          axis = DrawingDatums.section_axis(section)
          [a, b].all? { |point| (point[axis] - section.fetch('offset')).abs < 0.01 }
        end

        z = rim.z.to_mm
        ColumnCuts.clip(b, a, masks).flat_map do |first, last|
          GridStyle.add_axis(entities, API.point(*first, z), API.point(*last, z))
        end
      end

      def populate(group, level, cut_height, hidden, masks: [], hollow_masks: [], dimension_openings: false,
                   sections: [], dimension_overall: true)
        extent = Geom::BoundingBox.new
        stats, projections = walls(group.model, group.entities, cut_height, hidden, extent, masks,
                                   hollow_masks: hollow_masks, dimension_openings: dimension_openings)
        grid_data = grids(group.model, group.entities, level, cut_height, hidden, aligned: dimension_openings,
                          sections: sections, dimensions: dimension_overall)
        stats[:grids] = grid_data.size
        stats[:overall_dimensions] = dimension_overall ? overall_dimensions(group.entities, extent, aligned: dimension_openings) : 0
        group.entities.each { |entity| entity.layer = group.model.layers[0] }
        [stats, projections, grid_data]
      end
    end
  end
end
