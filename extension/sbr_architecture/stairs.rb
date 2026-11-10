# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Stairs
      API = SbrArchitecture
      DIRECTIONS = { 'x+' => 'X＋へ上る', 'x-' => 'X−へ上る', 'y+' => 'Y＋へ上る', 'y-' => 'Y−へ上る' }.freeze
      module_function

      def items(model)
        model.entities.grep(Sketchup::Group).select { |item| Follow.kind(item) == 'stair' }
      end

      def linked?(slab, id)
        items(slab.model).any? do |stair|
          Follow.parameters(stair).values_at('host_id', 'opening_id') == [slab.persistent_id, id]
        end
      end

      def dimensions(rect, direction, height, risers)
        raise ArgumentError, '上る方向を選んでください。' unless DIRECTIONS.key?(direction)
        raise ArgumentError, '蹴上げの段数は2〜60の整数にしてください。' unless risers&.between?(2, 60)
        raise ArgumentError, '上階の床は下階より上に置いてください。' if height <= Layout::MIN_MM

        ring = SlabOpenings.rectangle(*rect)
        axis = direction.start_with?('x') ? 0 : 1
        spans = ring[2].zip(ring[0]).map { |high, low| high - low }
        run = spans[axis]
        landing = [20.0, run * 0.03].min
        going = (run - landing) / (risers - 1)
        if [landing, going, height / risers.to_f].any? { |length| length < Layout::MIN_MM }
          raise ArgumentError, '段数に対して開口の長さか階高が足りません。'
        end

        { 'height' => height, 'run' => run, 'width' => spans[1 - axis], 'rect' => ring.values_at(0, 2), 'going' => going }
      end

      def resolve(model, params)
        slab = model.find_entity_by_persistent_id(params.fetch('host_id'))
        unless slab.is_a?(Sketchup::Group) && Follow.kind(slab) == 'slab'
          raise ArgumentError, '直階段の参照先の床がありません。階段を削除し、床と開口を選び直してください。'
        end
        transform = slab.transformation
        unless PlanLinework.upright?(transform) && [transform.xaxis, transform.yaxis, transform.zaxis].all? { |axis| (axis.length - 1).abs < 1e-6 } &&
               transform.xaxis.cross(transform.yaxis).samedirection?(transform.zaxis)
          raise ArgumentError, '直階段の参照先には、水平で拡大縮小や反転をしていない床を選んでください。'
        end

        host = Follow.parameters(slab)
        opening = host.fetch(SlabOpenings::KEY, []).find { |item| item['id'] == params['opening_id'] }
        raise ArgumentError, '直階段の参照先の床開口がありません。階段を編集するか削除してください。' unless opening

        base = API.levels(model)[params.fetch('level')]
        raise ArgumentError, '直階段の下階レベルを選び直してください。' unless base

        count = Integer(params['risers'].to_s, exception: false)
        rise = (transform.origin.z.to_mm - base).round(6)
        info = dimensions(opening.fetch('corners'), params.fetch('direction'), rise, count)
        [params.merge(info, 'risers' => count), transform]
      end

      def point_at(params, distance, across, z)
        a, b = params.fetch('rect')
        x, y = case params.fetch('direction')
               when 'x+' then [a[0] + distance, a[1] + across]
               when 'x-' then [b[0] - distance, b[1] - across]
               when 'y+' then [b[0] - across, a[1] + distance]
               when 'y-' then [a[0] + across, b[1] - distance]
               end
        API.point(x, y, z - params.fetch('height'))
      end

      def profile(params)
        height, run, count = params.values_at('height', 'run', 'risers')
        rise = height / count.to_f
        going = params.fetch('going')
        steps = (0...count).flat_map do |i|
          x = i * going
          [[x, rise * i], [x, rise * (i + 1)]]
        end
        # Keep the underside below the final tread, even for a steep stair.
        soffit = [height - [180.0, rise + 50.0].max, 0.0].max
        steps + [[run, height], [run, soffit]]
      end

      def write(group, params)
        points = profile(params)
        first, last = [0, params.fetch('width')].map { |w| points.reverse.map { |x, z| point_at(params, x, w, z) } }
        group.entities.build do |builder|
          builder.add_face(first)
          builder.add_face(last.reverse)
          first.each_index do |i|
            j = (i + 1) % first.size
            builder.add_face([first[j], first[i], last[i], last[j]])
          end
        end
        raise ArgumentError, '直階段をソリッドにできません。床開口と段数を確認してください。' unless group.manifold? && group.volume.positive?

        group.entities.each { |item| item.layer = group.model.layers[0] }
      end

      def apply(model, values, stair = nil)
        API.top_level!(model)
        API.operation(model, stair ? '直階段を編集' : '直階段を作成') do
          params, placement = resolve(model, values)
          duplicate = items(model).any? do |item|
            item != stair && Follow.parameters(item).values_at('host_id', 'opening_id') == params.values_at('host_id', 'opening_id')
          end
          raise ArgumentError, 'この開口にはすでに直階段があります。' if duplicate

          if stair
            rebuild(stair, params, placement)
          else
            stair = model.entities.add_group
            stair.name = '直階段'
            stair.layer = model.layers[0]
            write(stair, params)
            stair.transformation = placement
            API.store_params(stair, 'stair', params)
          end
          if (plan = Openings::PlanPick.active_spec(model))
            Drawings.generate(model, [plan], within_operation: true)
          end
        end
        model.selection.clear
        model.selection.add(stair)
        stair
      end

      def rebuild(stair, params, placement)
        raise ArgumentError, '関連する直階段のロックを解除してください。' if stair.locked?

        API.rebuild(stair, 'stair', params, Follow.parameters(stair), placement)
      end

      def refresh(model, host: nil)
        items(model).each do |stair|
          previous = Follow.parameters(stair)
          next if host && previous['host_id'] != host.persistent_id

          params, placement = resolve(model, previous)
          next if previous == params && stair.transformation.to_a == placement.to_a

          rebuild(stair, params, placement)
        end
      end

      def dialog(model, stair = nil)
        previous = stair ? Follow.parameters(stair) : {}
        slab = model.find_entity_by_persistent_id(previous['host_id']) if stair
        if stair && !slab&.valid?
          raise ArgumentError, '参照先の床がありません。階段を削除し、床と開口を選び直してください。'
        end
        slab ||= SlabOpenings.selected(model)
        openings = SlabOpenings.options(Follow.parameters(slab))
        raise ArgumentError, '先に上階の床に矩形の床開口を作ってください。' if openings.empty?

        levels = API.levels(model).select { |_, z| z < slab.transformation.origin.z.to_mm }.sort_by(&:last).map(&:first)
        raise ArgumentError, '先に上階の床より低い作図レベルを登録してください。' if levels.empty?

        selected = openings.find { |_, opening| opening['id'] == previous['opening_id'] }&.first || openings.keys.first
        level = levels.include?(previous['level']) ? previous['level'] : levels.last
        count = previous.fetch('risers', [2, ((slab.transformation.origin.z.to_mm - API.levels(model).fetch(level)) / 180).ceil].max)
        first, last = openings.fetch(selected).fetch('corners')
        default_direction = last[0] - first[0] >= last[1] - first[1] ? 'x+' : 'y+'
        direction = DIRECTIONS.fetch(previous.fetch('direction', default_direction))
        input = UI.inputbox(['上階の床開口', '下階レベル', '上る向き（床の軸）', '蹴上げの段数'],
                            [selected, level, direction, count.to_s],
                            [openings.keys.join('|'), levels.join('|'), DIRECTIONS.values.join('|'), ''], '直階段')
        return unless input

        key, lower, ascent, risers = input
        result = apply(model, { 'host_id' => slab.persistent_id, 'opening_id' => openings.fetch(key).fetch('id'),
                                'direction' => DIRECTIONS.key(ascent), 'level' => lower, 'risers' => risers }, stair)
        params = Follow.parameters(result)
        Sketchup.set_status_text(format('直階段｜蹴上げ %.1f mm・踏面 %.1f mm', params['height'] / params['risers'].to_f,
                                        params['going']), SB_PROMPT)
      end

      def draw_plan(entities, model, level, cut, hidden)
        stairs = items(model).select { |stair| !hidden.include?(stair.persistent_id) && stair.layer.visible? }
        stairs.count do |stair|
          params = Follow.parameters(stair)
          next false unless params['level'] == level

          height, run, width, risers = params.values_at('height', 'run', 'width', 'risers')
          at = ->(x, y) { point_at(params, x, y, height).transform(stair.transformation).tap { |point| point.z = (cut - 0.35).mm } }
          going = params.fetch('going')
          cut_above = cut - API.levels(model).fetch(level)
          split = (cut_above / (height / risers.to_f)).ceil
          risers.times do |index|
            x = index * going
            if index < split
              entities.add_line(at.call(x, 0), at.call(x, width))
            else
              5.times do |segment|
                y = segment * width / 5.0
                entities.add_line(at.call(x, y), at.call(x, y + width * 0.12))
              end
            end
          end
          [0, width].each { |y| entities.add_line(at.call(0, y), at.call(run, y)) }
          if split.between?(1, risers - 1)
            x = (split - 0.5) * going
            points = [[x - going * 0.3, 0], [x + going * 0.3, width * 0.45],
                      [x - going * 0.3, width * 0.55], [x + going * 0.3, width]]
            points.each_cons(2) { |a, b| entities.add_line(at.call(*a), at.call(*b)) }
          end
          center = width / 2.0
          arrow = [run * 0.42, [(split - 0.75) * going, run * 0.14].max].min
          entities.add_line(at.call(run * 0.05, center), at.call(arrow, center))
          [-1, 1].each { |side| entities.add_line(at.call(arrow, center), at.call(arrow - run * 0.06, center + side * width * 0.12)) }
          entities.add_text('UP', at.call(run * 0.06, width * 0.67))
          true
        end
      end
    end
  end
end
