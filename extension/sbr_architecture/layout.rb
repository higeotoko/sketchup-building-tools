# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Layout
      MIN_MM = 1.0
      MAX_SPANS = 40
      ECCENTRIC = '外・内寸法'
      ALIGNMENTS = ['中央', '左寄せ', '右寄せ', ECCENTRIC].freeze
      OUTSIDE_SIDES = { 'auto' => '自動（開いた経路は右）', 'left' => '進行方向の左', 'right' => '進行方向の右' }.freeze
      module_function

      def mm(value, label, positive: false)
        number = Float(value, exception: false)
        unless number&.finite? && (!positive || number >= MIN_MM)
          raise ArgumentError, "#{label}を#{positive ? '1以上の' : ''}数値（mm）で入力してください。"
        end

        number
      end

      def spans(value)
        result = []
        normalize(value).split(',', -1).each do |item|
          match = /\A\s*([^*]+?)\s*(?:\*\s*(\d+)\s*)?\z/.match(item)
          raise ArgumentError, '間隔は「910*4」または「910,1820,910」の形式で入力してください。' unless match

          count = match[2] ? match[2].to_i : 1
          unless count.positive? && result.size + count <= MAX_SPANS
            raise ArgumentError, "各方向のスパン数は1〜#{MAX_SPANS}にしてください。"
          end

          result.concat(Array.new(count, mm(match[1], '通り芯の間隔', positive: true)))
        end
        raise ArgumentError, '間隔を入力してください。' if result.empty?

        result
      end

      def labels(value, count)
        names = normalize(value).split(',', -1).map(&:strip)
        names = Array.new(count) { |i| "#{names.first}#{i + 1}" } if names.size == 1 && !names.first.empty?
        unless names.size == count && names.none?(&:empty?) && names.uniq.size == count
          raise ArgumentError, "符号は接頭辞1個、または#{count}個の異なる符号をカンマ区切りで入力してください。"
        end

        names
      end

      def normalize(value)
        value.to_s.strip.tr('０１２３４５６７８９，．＊', '0123456789,.*').tr('、×', ',*')
      end

      def stations(spans)
        spans.each_with_object([0.0]) { |span, values| values << values.last + span }
      end

      def slab_outline(points)
        outline = points.first == points.last ? points[0...-1] : points
        raise ArgumentError, '床の輪郭は異なる3点以上で指定してください。' unless outline.size >= 3 && outline.uniq.size == outline.size

        edges = (outline + [outline.first]).each_cons(2).to_a
        area2 = edges.sum { |(x1, y1), (x2, y2)| x1 * y2 - y1 * x2 }
        if area2.abs < MIN_MM || edges.any? { |a, b| Math.hypot(a[0] - b[0], a[1] - b[1]) < MIN_MM }
          raise ArgumentError, '床の輪郭に面積がないか、短すぎる辺があります。'
        end

        edges.each_with_index do |(a, b), i|
          edges.each_with_index do |(c, d), j|
            next if j <= i + 1 || (i.zero? && j == edges.size - 1)

            if segments_cross?(a, b, c, d)
              raise ArgumentError, '床の輪郭が交差しています。'
            end
          end
        end
        outline
      end

      def segments_cross?(a, b, c, d)
        return false if [0, 1].any? do |axis|
          first = [a[axis], b[axis]].minmax
          second = [c[axis], d[axis]].minmax
          first.last < second.first || second.last < first.first
        end

        turn = ->(p, q, r) { (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]) }
        turn.call(a, b, c) * turn.call(a, b, d) <= 0 && turn.call(c, d, a) * turn.call(c, d, b) <= 0
      end

      def wall_profiles(points, thickness, alignment)
        offsets = case alignment
                  when '中央' then [thickness / 2, -thickness / 2]
                  when '左寄せ' then [thickness, 0.0]
                  when '右寄せ' then [0.0, -thickness]
                  else raise ArgumentError, '壁の基準を選択してください。'
                  end
        offset_profiles(points, offsets)
      end

      def outside_side(points, side = 'auto')
        return side unless side == 'auto'

        x0, y0 = points.first
        area = points.each_cons(2).sum do |(x, y), (u, v)|
          (x - x0) * (v - y0) - (u - x0) * (y - y0)
        end
        points.size > 2 && points.first == points.last && area.negative? ? 'left' : 'right'
      end

      def wall_parameters(thickness, height, alignment, outer: nil, inner: nil, outside_side: 'auto')
        raise ArgumentError, '壁の基準を選択してください。' unless ALIGNMENTS.include?(alignment)

        params = { 'height' => mm(height, '壁高さ', positive: true), 'alignment' => alignment }
        if alignment == ECCENTRIC
          raise ArgumentError, '外側の向きを選択してください。' unless OUTSIDE_SIDES.key?(outside_side)

          outer = mm(outer, '芯から外面')
          inner = mm(inner, '芯から内面')
          thickness = outer + inner
          params.merge!('outer_offset' => outer, 'inner_offset' => inner, 'outside_side' => outside_side)
        end
        params.merge('thickness' => mm(thickness, '壁厚', positive: true))
      end

      def wall_outside(params)
        return unless params['alignment'] == ECCENTRIC

        outside_side(params.fetch('points'), params.fetch('outside_side', 'auto'))
      end

      def wall_profile_for(params)
        points, thickness, alignment = params.values_at('points', 'thickness', 'alignment')
        return wall_profiles(points, thickness, alignment) unless alignment == ECCENTRIC

        outer, inner = params.values_at('outer_offset', 'inner_offset')
        offsets = wall_outside(params) == 'left' ? [outer, -inner] : [inner, -outer]
        offset_profiles(points, offsets)
      end

      def offset_profiles(points, offsets)
        if points.size < 2
          raise ArgumentError, '壁の芯を2点以上指定してください。'
        end

        closed = points.size > 2 && points.first == points.last
        vertices = closed ? points[0...-1] : points
        if (closed && vertices.size < 3) || vertices.uniq.size != vertices.size
          raise ArgumentError, '壁の芯が同じ点を複数回通っています。'
        end

        normals = points.each_cons(2).map do |a, b|
          dx = b[0] - a[0]
          dy = b[1] - a[1]
          length = Math.hypot(dx, dy)
          raise ArgumentError, '壁の各区間は1 mm以上にしてください。' if length < MIN_MM

          [-dy / length, dx / length]
        end
        joins = vertices.each_index.map do |i|
          if !closed && i.zero?
            normals.first
          elsif !closed && i == vertices.size - 1
            normals.last
          else
            join_normal(normals[i - 1], normals[i])
          end
        end
        sides = vertices.zip(joins).map do |(x, y), (nx, ny)|
          offsets.map { |offset| [x + nx * offset, y + ny * offset] }
        end
        sides << sides.first if closed
        profiles = sides.each_cons(2).map do |(left_a, right_a), (left_b, right_b)|
          [left_a, right_a, right_b, left_b]
        end
        validate_profiles(profiles)
        profiles
      end

      def join_normal(previous, following)
        denominator = 1 + previous.zip(following).sum { |a, b| a * b }
        if denominator < 0.125
          raise ArgumentError, '壁の折り返しが急です。角を分けて作図してください。'
        end

        previous.zip(following).map { |a, b| (a + b) / denominator }
      end

      def validate_profiles(profiles)
        profiles.each do |profile|
          profile.each_index do |i|
            a, b, c = [profile[i], profile[(i + 1) % 4], profile[(i + 2) % 4]]
            turn = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
            raise ArgumentError, '角に対して壁が厚すぎるか、区間が短すぎます。' unless turn > 0.01
          end
        end
        profiles.combination(2).each do |a, b|
          raise ArgumentError, '壁の区間同士が重なります。芯の経路を確認してください。' if overlap?(a, b)
        end
      end

      def overlap?(a, b)
        [a, b].all? do |polygon|
          (polygon + [polygon.first]).each_cons(2).all? do |p, q|
            nx = p[1] - q[1]
            ny = q[0] - p[0]
            a_min, a_max = a.map { |x, y| x * nx + y * ny }.minmax
            b_min, b_max = b.map { |x, y| x * nx + y * ny }.minmax
            [a_max, b_max].min - [a_min, b_min].max > Math.hypot(nx, ny) * 0.0001
          end
        end
      end
    end
  end
end
