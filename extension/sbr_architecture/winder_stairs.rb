# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module WinderStairs
      Tread = Struct.new(:entry, :exit, :outline)
      TURNS = { 'none' => 'なし', 'left2' => '左90°・2段', 'left3' => '左90°・3段',
                'right2' => '右90°・2段', 'right3' => '右90°・3段' }.freeze
      module_function

      def dimensions(run, width, risers, start_turn, end_turn)
        straight_run = run - [start_turn, end_turn].count { |turn| turn != 'none' } * width
        straight_steps = risers - count(start_turn) - count(end_turn) - (end_turn == 'none' ? 1 : 0)
        if straight_run < 2 || straight_steps < 1 || width < 20
          raise ArgumentError, '回り段が開口に納まりません。開口を長くするか、中間の向き・段数・回り段を調整してください。'
        end

        landing = end_turn == 'none' ? [20.0, straight_run * 0.03].min : 0.0
        going = (straight_run - landing) / straight_steps
        if going < 1 || (end_turn == 'none' && landing < 1)
          raise ArgumentError, '直線部分の踏面を確保できません。開口の長さか段数を調整してください。'
        end

        { 'going' => going, 'straight_steps' => straight_steps, 'top_landing' => landing }
      end

      def count(turn)
        turn == 'none' ? 0 : turn[-1].to_i
      end

      def fan(run, width, turn, start:)
        return [] if turn == 'none'

        steps = count(turn)
        # Trim the inside point so adjacent risers can be built as a solid.
        bevel = [width * 0.10, 90.0].min
        pivot = start ? width : run - width
        along = start ? -1 : 1
        across = turn.start_with?('left') ? -1 : 1
        transform = ->(u, v) { [(pivot + along * u).round(6), (across == 1 ? v : width - v).round(6)] }
        angles = (0..steps).map { |index| 90.0 * index / steps }
        angles.reverse! unless start
        seam = lambda do |degrees|
          angle = degrees * Math::PI / 180
          u, v = Math.cos(angle), Math.sin(angle)
          inner, outer = bevel / (u + v), width / [u, v].max
          [transform.call(u * inner, v * inner), transform.call(u * outer, v * outer)]
        end
        angles.zip(angles.map(&seam)).each_cons(2).map do |(a, entry), (b, exit)|
          bend = [transform.call(width, width)] if [a, b].min < 45 && [a, b].max > 45
          tread(entry, exit, bend || [])
        end
      end

      def tread(entry, exit, bend = [])
        ring = [entry[0], entry[1], *bend, exit[1], exit[0]]
        ring.reverse! if ColumnCuts.signed_area(ring).negative?
        Tread.new(entry, exit, ring)
      end

      def treads(params)
        run, width, start_turn, end_turn, going, steps, landing =
          params.values_at('run', 'width', 'start_turn', 'end_turn', 'going', 'straight_steps', 'top_landing')
        first = fan(run, width, start_turn, start: true)
        last = fan(run, width, end_turn, start: false)
        start = first.empty? ? 0 : width
        finish = last.empty? ? run - landing : run - width
        seams = (0..steps).map do |index|
          x = index == steps ? finish : start + index * going
          [[x.round(6), 0], [x.round(6), width]]
        end
        # Maintain low-to-high Y order along the straight run, including the
        # truncated ends of the fan.
        seams[0] = first.last.exit.sort_by(&:last) if first.any?
        seams[-1] = last.first.entry.sort_by(&:last) if last.any?
        seams << [[run, 0], [run, width]] if landing.positive?
        first + seams.each_cons(2).map { |entry, exit| tread(entry, exit) } + last
      end

      def same_seam?(seam, a, b)
        seam.include?(a) && seam.include?(b)
      end

      def shell(treads, height)
        rise = height / treads.size
        thickness = rise * 1.6
        levels = treads.each_index.map do |index|
          top = index == treads.size - 1 ? height : (index + 1) * rise
          [[top - thickness, 0.0].max, top]
        end
        treads.each_with_index.flat_map do |step, index|
          low, high = levels[index]
          previous = levels[index - 1] if index.positive?
          following = levels[index + 1]
          faces = [step.outline.map { |xy| [*xy, high] }, step.outline.reverse.map { |xy| [*xy, low] }]
          SlabOpenings.perimeter(step.outline).each do |a, b|
            if previous && same_seam?(step.entry, a, b)
              faces << side(a, b, previous.last, high)
            elsif following && same_seam?(step.exit, a, b)
              faces << side(a, b, low, following.first) if following.first > low
            else
              stops = lambda do |point|
                z = previous.last if previous && step.entry.include?(point)
                z = following.first if following && step.exit.include?(point)
                z if z && z > low && z < high
              end
              middle_a, middle_b = [a, b].map(&stops)
              wall = side(a, b, low, high, middle_a, middle_b)
              if middle_a || middle_b
                # Triangulate to preserve the intermediate vertices on the
                # adjoining riser edges.
                center = [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0, (low + high) / 2.0]
                faces.concat(SlabOpenings.perimeter(wall).map { |p, q| [center, p, q] })
              else
                faces << wall
              end
            end
          end
          faces
        end
      end

      def side(a, b, low, high, middle_a = nil, middle_b = nil)
        [[*a, low], [*b, low], ([*b, middle_b] if middle_b), [*b, high], [*a, high],
         ([*a, middle_a] if middle_a)].compact
      end

      def write(group, params)
        faces = shell(treads(params), params.fetch('height').to_f)
        group.entities.build do |builder|
          faces.each { |face| builder.add_face(face.map { |x, y, z| Stairs.point_at(params, x, y, z) }) }
        end
        group.entities.grep(Sketchup::Edge).each do |edge|
          adjacent = edge.faces
          edge.hidden = true if adjacent.size == 2 && adjacent[0].normal.samedirection?(adjacent[1].normal)
        end
      end

      def interpolate(a, b, t)
        a.zip(b).map { |first, last| first + (last - first) * t }
      end

      def draw_plan(entities, params, at, split)
        steps = treads(params)
        line = ->(a, b) { entities.add_line(at.call(*a), at.call(*b)) }
        dashed = lambda do |a, b|
          length = Math.hypot(b[0] - a[0], b[1] - a[1])
          pieces = [(length / 160.0).ceil, 1].max
          pieces.times { |i| line.call(interpolate(a, b, i.to_f / pieces), interpolate(a, b, (i + 0.65) / pieces)) }
        end
        steps.each_with_index do |step, i|
          stroke = i < split ? line : dashed
          SlabOpenings.perimeter(step.outline).each do |a, b|
            next if same_seam?(step.exit, a, b) && i < steps.size - 1
            next if same_seam?(step.entry, a, b) && i == split && split.positive?

            stroke.call(a, b)
          end
        end
        if split.between?(1, steps.size - 1)
          a, b = steps[split].entry
          dx, dy = b[0] - a[0], b[1] - a[1]
          points = [a, interpolate(a, b, 0.44), interpolate(a, b, 0.56), b]
          points[1] = [points[1][0] - dy * 0.07, points[1][1] + dx * 0.07]
          points[2] = [points[2][0] + dy * 0.07, points[2][1] - dx * 0.07]
          points.each_cons(2) { |p, q| line.call(p, q) }
        end

        visible = steps.take(split.clamp(1, steps.size))
        path = visible.map { |step| interpolate(*step.entry, 0.5) }
        path << interpolate(*visible.last.exit, 0.5)
        path[0] = interpolate(path[0], path[1], 0.20)
        path[-1] = interpolate(path[-2], path[-1], 0.65)
        path.each_cons(2) { |a, b| line.call(a, b) }
        a, b = path.last(2)
        dx, dy = b[0] - a[0], b[1] - a[1]
        [-1, 1].each { |side| line.call(b, [b[0] - dx * 0.42 + side * dy * 0.25, b[1] - dy * 0.42 - side * dx * 0.25]) }
        entities.add_text('UP', at.call(*interpolate(*steps.first.entry, 0.75)))
      end
    end
  end
end
