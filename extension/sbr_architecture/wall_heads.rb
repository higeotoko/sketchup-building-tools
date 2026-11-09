# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module WallHeads
      API = SbrArchitecture
      MODES = {
        'fixed' => '固定高さ',
        'slab' => '床下面で止める',
        'beam' => '梁下で止める',
        'exterior' => '外壁を上階につなぐ'
      }.freeze
      SIDES = { 'left' => '左（最初の層）', 'right' => '右（最後の層）' }.freeze
      TOLERANCE_MM = 0.1
      module_function

      def layer_height(params, index)
        head = params['head']
        if head && head['mode'] == 'exterior' && index == exterior_index(params)
          head.fetch('outside_height')
        else
          params.fetch('height')
        end
      end

      def exterior_index(params)
        params.fetch('head').fetch('side') == 'left' ? 0 : params.fetch('layers').length - 1
      end

      def overall_height(params)
        params.dig('head', 'outside_height') || params.fetch('height')
      end

      def apply(wall, rule)
        raise ArgumentError, '壁を1つ選択してください。' unless Follow.kind(wall) == 'wall'
        raise ArgumentError, '壁のロックを解除してください。' if wall.locked?

        params = Follow.parameters(wall)
        if rule
          params['head'] = rule
        else
          return unless params.delete('head')
        end
        API.regenerate(wall, params)
      end

      def target!(wall, id, kinds)
        target = wall.model.find_entity_by_persistent_id(id.to_i) if id
        unless target.is_a?(Sketchup::Group) && target != wall && kinds.include?(Follow.kind(target))
          raise ArgumentError, "「#{wall.name}」の納まりの参照先を選び直してください。"
        end
        target
      end

      def resolve(wall, params, placement)
        head = params['head']
        return params unless head

        mode = head.fetch('mode')
        raise ArgumentError, '壁上端の納まりを選んでください。' unless MODES.key?(mode) && mode != 'fixed'

        kinds = mode == 'exterior' ? %w[slab beam] : [mode]
        stop = target!(wall, head['stop'], kinds)
        unless PlanLinework.upright?(placement) && PlanLinework.upright?(API.placement_for(stop, Follow.kind(stop), Follow.parameters(stop)))
          raise ArgumentError, '納まりを設定する壁・床・梁は水平な作図面に置いてください。'
        end

        inverse = placement.inverse
        bounds = stop.bounds
        raise ArgumentError, '参照先の床または梁に形状がありません。' unless bounds.valid?

        height = bounds.min.transform(inverse).z.to_mm.round(6)
        raise ArgumentError, "「#{wall.name}」の参照面が壁脚より上にありません。" if height < Layout::MIN_MM

        updated = params.merge('height' => height)
        return updated unless mode == 'exterior'

        upper = target!(wall, head['upper'], ['wall'])
        raise ArgumentError, '上階の外壁は水平な作図面に置いてください。' unless PlanLinework.upright?(upper.transformation)

        outside = upper.transformation.origin.transform(inverse).z.to_mm.round(6)
        raise ArgumentError, '上階の外壁の下端は、指定した床下面または梁下より上に置いてください。' if outside <= height
        updated.merge('head' => head.merge('outside_height' => outside)).tap do |resolved|
          validate_exterior(resolved, placement, stop, upper)
        end
      end

      def xy(point)
        [point.x.to_mm, point.y.to_mm]
      end

      def world_profile(profile, placement)
        profile.map { |x, y| xy(API.point(x, y).transform(placement)) }
      end

      def side_edges(profiles)
        profiles.flat_map { |a, b, c, d| [[a, d], [b, c]] }
      end

      def spans_edge?(edge, other)
        start, finish = other
        dx, dy = finish.zip(start).map { |a, b| a - b }
        length = Math.hypot(dx, dy)
        return false if length < TOLERANCE_MM

        edge.all? do |x, y|
          px, py = x - start[0], y - start[1]
          along = (px * dx + py * dy) / length
          (px * dy - py * dx).abs / length <= TOLERANCE_MM &&
            along.between?(-TOLERANCE_MM, length + TOLERANCE_MM)
        end
      end

      def validate_exterior(params, placement, stop, upper)
        bands = Composition.bands(params)
        if bands.length < 2 || !SIDES.key?(params.dig('head', 'side'))
          raise ArgumentError, '外壁をつなぐには、壁を2層以上に分けて外装側を指定してください。'
        end

        _, _, from, to = bands.fetch(exterior_index(params))
        skins = API.wall_profiles(params).map do |profile|
          world_profile(Composition.wall_profile(profile, from, to, params.fetch('thickness')), placement)
        end
        upper_edges = side_edges(API.wall_profiles(Follow.parameters(upper)).map { |profile| world_profile(profile, upper.transformation) })
        outer_edge = params.dig('head', 'side') == 'left' ? [0, 3] : [1, 2]
        unless skins.all? { |skin| upper_edges.any? { |edge| spans_edge?(skin.values_at(*outer_edge), edge) } }
          raise ArgumentError, '指定した外装面と上階外壁がそろっていません。外装側と壁の位置を確認してください。'
        end
        footprints = stop_profiles(stop)
        if skins.any? { |skin| footprints.any? { |profile| Layout.overlap?(skin, profile) } }
          raise ArgumentError, '延長する外装層が指定した床または梁と重なります。外装側か部材位置を確認してください。'
        end
      end

      def stop_profiles(stop)
        params = Follow.parameters(stop)
        kind = Follow.kind(stop)
        if kind == 'beam'
          if params['system'] == 'steel'
            bounds = stop.definition.bounds
            min, max = bounds.min, bounds.max
            points = [[min.x, min.y], [max.x, min.y], [max.x, max.y], [min.x, max.y]]
            return [points.map { |x, y| xy(Geom::Point3d.new(x, y, 0).transform(stop.transformation)) }]
          end
          return [world_profile(API.member_profile(kind, params), API.placement_for(stop, kind, params))]
        end

        outline = Layout.slab_outline(params.fetch('points'))
        points = outline.map { |x, y| API.point(x, y).transform(stop.transformation) }
        area = points.zip(points.rotate).sum { |a, b| a.x.to_f * b.y.to_f - b.x.to_f * a.y.to_f }
        points.reverse! if area.negative?
        triangles = Geom.tesselate(points)
        raise ArgumentError, '参照先の床輪郭を確認できません。' if triangles.empty?

        triangles.each_slice(3).map { |triangle| triangle.map { |point| xy(point) } }
      end

      def refresh(model, changed: nil)
        model.entities.grep(Sketchup::Group).each do |wall|
          next unless Follow.kind(wall) == 'wall'

          params = Follow.parameters(wall)
          head = params['head']
          next unless head
          next if changed && !head.values_at('stop', 'upper').include?(changed.persistent_id.to_s)

          resolved = resolve(wall, params, wall.transformation)
          next if resolved == params
          raise ArgumentError, "納まりを更新するには「#{wall.name}」のロックを解除してください。" if wall.locked?

          API.rebuild(wall, 'wall', resolved, params, wall.transformation)
        end
      end

      def update(model)
        API.top_level!(model)
        API.operation(model, '壁上端の納まりを更新') { refresh(model) }
      end

      def check_current!(model)
        model.entities.grep(Sketchup::Group).each do |wall|
          next unless Follow.kind(wall) == 'wall'

          params = Follow.parameters(wall)
          next unless params['head'] && resolve(wall, params, wall.transformation) != params

          raise ArgumentError, "「#{wall.name}」の形状が変わりました。「壁上端の納まりを更新」を実行してください。"
        end
      end

      def pick(wall)
        model = wall.model
        API.top_level!(model)
        raise ArgumentError, '壁のロックを解除してください。' if wall.locked?

        head = Follow.parameters(wall).fetch('head', {})
        answer = UI.inputbox(['壁上端'], [MODES.fetch(head.fetch('mode', 'fixed'))], [MODES.values.join('|')], '壁上端の納まり')
        return unless answer

        mode = MODES.key(answer.first)
        raise ArgumentError, '壁上端の納まりを選んでください。' unless mode
        return apply(wall, nil) if mode == 'fixed'

        stops = options(wall, mode == 'exterior' ? %w[slab beam] : [mode])
        raise ArgumentError, '壁脚より上にある参照先の床または梁を用意してください。' if stops.empty?

        prompts = ['止める面の参照先']
        defaults = [stops.key(head['stop']) || stops.keys.first]
        choices = [stops.keys.join('|')]
        if mode == 'exterior'
          uppers = options(wall, ['wall'])
          raise ArgumentError, '先に上階の外壁を作成してください。' if uppers.empty?

          prompts.concat(['つなぐ上階の外壁', '延長する外装側'])
          defaults.concat([uppers.key(head['upper']) || uppers.keys.first, SIDES.fetch(head['side'], SIDES.fetch('right'))])
          choices.concat([uppers.keys.join('|'), SIDES.values.join('|')])
        end
        values = UI.inputbox(prompts, defaults, choices, MODES.fetch(mode))
        return unless values

        rule = { 'mode' => mode, 'stop' => stops.fetch(values.first) }
        rule.merge!('upper' => uppers.fetch(values[1]), 'side' => SIDES.key(values[2])) if mode == 'exterior'
        apply(wall, rule)
      end

      def options(wall, kinds)
        bottom = wall.transformation.origin.z
        rows = wall.model.entities.grep(Sketchup::Group).filter_map do |item|
          kind = Follow.kind(item)
          next unless item != wall && kinds.include?(kind)

          z = kind == 'wall' ? item.transformation.origin.z : item.bounds.min.z
          next unless z > bottom

          level = Follow.parameters(item)['level'] || '階未指定'
          id = item.persistent_id.to_s
          ["#{level}・#{API.object_name(kind)}｜#{item.name.tr('|', '｜')}｜Z #{z.to_mm.round(1)} mm ##{id}", id, kinds.index(kind), z]
        end
        rows.sort_by { |_, _, order, z| [order, z] }.map { |label, id, _, _| [label, id] }.to_h
      end
    end
  end
end
