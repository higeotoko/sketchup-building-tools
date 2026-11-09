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
          [rectangles, openings, at, a[1], b[1]]
        end
      end

      def point_key(point)
        point.to_a.map { |length| length.to_mm.round(4) }
      end

      def walls(model, entities, cut_height, hidden)
        result = { wall_edges: 0, opening_marks: 0, skipped_walls: 0 }
        model.entities.grep(Sketchup::Group).each do |wall|
          next unless Follow.kind(wall) == 'wall' && !hidden.include?(wall.persistent_id) && wall.layer.visible?

          transform = wall.transformation
          if !upright?(transform)
            result[:skipped_walls] += 1
            next
          end
          local_z = API.point(0, 0, cut_height).transform(transform.inverse).z.to_mm
          edges = {}
          project = lambda do |p|
            world = p.transform(transform)
            Geom::Point3d.new(world.x, world.y, (cut_height - 0.5).mm)
          end
          slices(Follow.parameters(wall), local_z).each do |loops, openings, at, left, right|
            loops.each do |loop|
              points = loop.map { |p| project.call(p) }
              (points + [points.first]).each_cons(2) do |a, b|
                key = [point_key(a), point_key(b)].sort
                edges.key?(key) ? edges.delete(key) : edges[key] = [a, b]
              end
            end
            openings.each do |x1, x2, opening|
              draw_opening(entities, opening, x1, x2, left, right, local_z, at, project)
              result[:opening_marks] += 1
            end
          end
          edges.each_value { |a, b| entities.add_line(a, b) }
          result[:wall_edges] += edges.size
        end
        result
      end

      def draw_opening(entities, opening, x1, x2, left, right, z, at, project)
        middle = (left + right) / 2
        offsets = opening['kind'] == 'window' ? [(left + middle) / 2, (right + middle) / 2] : [middle]
        offsets.each do |lateral|
          entities.add_line(project.call(at.call(x1, lateral, z)), project.call(at.call(x2, lateral, z)))
        end
        mark = opening['mark'].to_s
        mark = opening['kind'] == 'window' ? '窓' : '扉' if mark.empty?
        entities.add_text(mark, project.call(at.call((x1 + x2) / 2, left + 150, z)))
      end

      def grids(model, entities, level, cut_height, hidden)
        model.entities.grep(Sketchup::Group).count do |grid|
          next false unless Follow.kind(grid) == 'grid' && !hidden.include?(grid.persistent_id) &&
                            grid.layer.visible? && upright?(grid.transformation)

          params = Follow.parameters(grid)
          next false if params['level'] && params['level'] != level

          copy = entities.add_group
          copy.name = grid.name
          copy.layer = model.layers[0]
          API.write_grid(copy, params)
          z = (cut_height - 0.5).mm - grid.transformation.origin.z
          copy.transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z)) * grid.transformation
          copy.entities.each { |entity| entity.layer = model.layers[0] }
          true
        end
      end

      def populate(group, level, cut_height, hidden)
        stats = walls(group.model, group.entities, cut_height, hidden)
        stats[:grids] = grids(group.model, group.entities, level, cut_height, hidden)
        group.entities.each { |entity| entity.layer = group.model.layers[0] }
        stats
      end
    end
  end
end
