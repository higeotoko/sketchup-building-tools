# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Roof
      API = SbrArchitecture
      TYPES = { 'shed' => '片流れ', 'gable' => '切妻' }.freeze
      DIRECTIONS = { 'x+' => 'X方向（＋側が高い）', 'x-' => 'X方向（−側が高い）',
                     'y+' => 'Y方向（＋側が高い）', 'y-' => 'Y方向（−側が高い）' }.freeze
      DEFAULTS = { 'roof_type' => 'gable', 'rise_direction' => 'y+', 'pitch' => 4.0, 'overhang' => 450.0,
                   'eave_offset' => 2700.0, 'thickness' => 120.0 }.freeze
      PLANE_EPSILON = 1e-6
      module_function

      def parameters(input)
        values = DEFAULTS.merge(input)
        type, direction = values.values_at('roof_type', 'rise_direction')
        raise ArgumentError, '屋根形式と勾配方向を選んでください。' unless TYPES.key?(type) && DIRECTIONS.key?(direction)

        pitch = Float(values['pitch'], exception: false)
        raise ArgumentError, '屋根勾配は0より大きく20寸以下で入力してください。' unless pitch&.finite? && pitch.positive? && pitch <= 20

        overhang = Layout.mm(values['overhang'], '軒の出')
        raise ArgumentError, '軒の出は0以上で入力してください。' if overhang.negative?

        { 'roof_type' => type, 'rise_direction' => direction, 'pitch' => pitch, 'overhang' => overhang,
          'eave_offset' => Layout.mm(values['eave_offset'], '基準から軒上端まで'),
          'thickness' => Layout.mm(values['thickness'], '屋根厚', positive: true) }
      end

      # Two opposite corners of the wall outline, measured from the placement datum.
      def surface_ends(params)
        dx, dy = params.fetch('end')
        raise ArgumentError, '屋根外周の幅と奥行きは1 mm以上必要です。' if [dx, dy].any? { |value| value.abs < Layout::MIN_MM }

        x, y = [dx, dy].map { |value| [0.0, value].minmax }
        overhang = params.fetch('overhang')
        direction = params.fetch('rise_direction')
        across_x = direction.start_with?('x')
        across, along = across_x ? [x, y] : [y, x]
        a, b = across.first - overhang, across.last + overhang
        eave = params.fetch('eave_offset')
        rise = (b - a) * params.fetch('pitch') / 10.0
        section = if params.fetch('roof_type') == 'gable'
                    [[a, eave], [(a + b) / 2.0, eave + rise / 2.0], [b, eave]]
                  elsif direction.end_with?('+')
                    [[a, eave], [b, eave + rise]]
                  else
                    [[a, eave + rise], [b, eave]]
                  end
        [along.first - overhang, along.last + overhang].map do |station|
          section.map { |distance, z| across_x ? [distance, station, z] : [station, distance, z] }
        end
      end

      def solid_ends(params)
        thickness = params.fetch('thickness')
        surface_ends(params).map do |top|
          bottom = top.reverse.map { |x, y, z| [x, y, z - thickness] }
          (top + bottom).map { |point| API.point(*point) }
        end
      end

      def write(group, params)
        first, last = solid_ends(params)
        along = last.first - first.first
        normal = (first[1] - first[0]).cross(first[-1] - first[0])
        if normal.dot(along).positive?
          first.reverse!
          last.reverse!
        end
        front = group.entities.add_face(first)
        back = group.entities.add_face(last.reverse)
        raise ArgumentError, '屋根の断面を作成できません。' unless front && back

        front.reverse! if front.normal.dot(along).positive?
        back.reverse! if back.normal.dot(along).negative?
        first.each_index do |i|
          j = (i + 1) % first.size
          side = group.entities.add_face([first[j], first[i], last[i], last[j]])
          expected = (first[i] - first[j]).cross(along)
          side.reverse! if side && side.normal.dot(expected).negative?
        end
        raise ArgumentError, '屋根をソリッドにできません。入力寸法を確認してください。' unless group.manifold?

        group.entities.each { |entity| entity.layer = group.model.layers[0] }
      end

      def roof_planes(params)
        params.dig('head', 'planes') if params.dig('head', 'mode') == 'roof'
      end

      def plane_height(plane, (x, y))
        a, b, c = plane
        a * x + b * y + c
      end

      def roof_height(planes, point)
        planes.map { |plane| plane_height(plane, point) }.min
      end

      def split_point(a, b, da, db)
        fraction = da / (da - db)
        a.zip(b).map { |start, finish| start + (finish - start) * fraction }
      end

      def clip_profile(profile)
        profile.zip(profile.rotate).flat_map do |a, b|
          da, db = [a, b].map { |point| near_plane(yield(point)) }
          points = []
          points << a unless da.negative?
          points << split_point(a, b, da, db) if da * db < 0
          points
        end
      end

      def roof_caps(planes, profile)
        return [profile] if planes.one?

        planes.map.with_index do |plane, index|
          other = planes[1 - index]
          clip_profile(profile) { |point| plane_height(other, point) - plane_height(plane, point) }
        end.select { |loop| loop.size >= 3 }
      end

      def roof_edge(planes, a, b)
        return [a, b] if planes.one?

        first, last = planes
        da, db = [a, b].map { |point| near_plane(plane_height(first, point) - plane_height(last, point)) }
        da * db < 0 ? [a, split_point(a, b, da, db), b] : [a, b]
      end

      def near_plane(distance)
        distance.abs < PLANE_EPSILON ? 0.0 : distance
      end

      def elevation_data(groups, hidden)
        candidates = groups.select { |group| Follow.kind(group) == 'roof' && !hidden.include?(group.persistent_id) && group.layer.visible? }
        return {} unless candidates.one?

        roof = candidates.first
        params = Follow.parameters(roof)
        eave, high = surface_ends(params).flatten(1).map { |point| API.point(*point).transform(roof.transformation).z.to_mm.round(1) }.minmax
        { 'eave' => eave, (params['roof_type'] == 'gable' ? 'ridge' : 'roof_high') => high }
      end
    end
  end
end
