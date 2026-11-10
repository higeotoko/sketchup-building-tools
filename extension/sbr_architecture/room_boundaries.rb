# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class RoomBoundaries
      EPSILON = 0.001

      def initialize(walls, voids = [])
        @walls, @voids = walls, voids
        segments = walls.flat_map { |loop| loop.zip(loop.rotate) }.reject { |a, b| a == b }
        @regions = faces(segments)
      end

      def region_at(point)
        return if @walls.any? { |wall| ColumnCuts.contains?(wall, point) } || @voids.any? { |loop| ColumnCuts.contains?(loop, point) }

        @regions.find { |loop| ColumnCuts.contains?(loop, point) }
      end

      def area(region)
        removed = @voids.sum do |loop|
          # The floor tool creates convex rectangles. Clipping against their
          # four sides also handles openings that cross the room boundary.
          boundary = ColumnCuts.signed_area(loop).negative? ? loop.reverse : loop
          intersection = boundary.zip(boundary.rotate).reduce(region) do |polygon, (a, b)|
            Roof.clip_profile(polygon) { |p| cross(subtract(b, a), subtract(p, a)) }
          end
          intersection.size < 3 ? 0 : ColumnCuts.signed_area(intersection).abs
        end
        ColumnCuts.signed_area(region) - removed
      end

      def subtract(a, b)
        [a[0] - b[0], a[1] - b[1]]
      end

      def cross(a, b)
        a[0] * b[1] - a[1] * b[0]
      end

      def split(a, b, c, d, first, second)
        return unless [0, 1].all? do |axis|
          low, high = [a[axis], b[axis]].minmax
          start, finish = [c[axis], d[axis]].minmax
          low <= finish + EPSILON && start <= high + EPSILON
        end

        r, s, delta = subtract(b, a), subtract(d, c), subtract(c, a)
        denominator = cross(r, s)
        if denominator.abs > 1e-8
          t, u = cross(delta, s) / denominator.to_f, cross(delta, r) / denominator.to_f
          if t.between?(-1e-9, 1 + 1e-9) && u.between?(-1e-9, 1 + 1e-9)
            first << t.clamp(0.0, 1.0)
            second << u.clamp(0.0, 1.0)
          end
        elsif cross(delta, r).abs <= EPSILON * Math.hypot(*r)
          axis = r[0].abs > r[1].abs ? 0 : 1
          [c, d].each do |p|
            t = (p[axis] - a[axis]) / r[axis].to_f
            first << t if t.between?(0, 1)
          end
          [a, b].each do |p|
            u = (p[axis] - c[axis]) / s[axis].to_f
            second << u if u.between?(0, 1)
          end
        end
      end

      def faces(segments)
        breaks = Array.new(segments.size) { [0.0, 1.0] }
        segments.each_with_index do |(a, b), i|
          ((i + 1)...segments.size).each do |j|
            c, d = segments[j]
            split(a, b, c, d, breaks[i], breaks[j])
          end
        end
        neighbors = Hash.new { |hash, point| hash[point] = [] }
        segments.zip(breaks).each do |(a, b), spans|
          points = spans.sort.map { |t| a.zip(b).map { |start, finish| (start + (finish - start) * t).round(3) } }.uniq
          points.each_cons(2) do |first, last|
            neighbors[first] << last unless neighbors[first].include?(last)
            neighbors[last] << first unless neighbors[last].include?(first)
          end
        end
        next_edges = {}
        neighbors.each do |point, others|
          others.sort_by! { |x, y| Math.atan2(y - point[1], x - point[0]) }
          others.each_with_index { |from, index| next_edges[[from, point]] = [point, others[index - 1]] }
        end
        loops = []
        until next_edges.empty?
          edge = next_edges.keys.first
          loop = []
          while (following = next_edges.delete(edge))
            loop << edge.first
            edge = following
          end
          loops << loop if loop.size >= 3 && ColumnCuts.signed_area(loop) > 1
        end
        loops.sort_by { |loop| ColumnCuts.signed_area(loop) }
      end
    end
  end
end
