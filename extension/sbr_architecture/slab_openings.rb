# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module SlabOpenings
      API = SbrArchitecture
      KEY = 'floor_openings'
      module_function

      def rectangle(a, b)
        low, high = a.zip(b).map(&:minmax).transpose
        raise ArgumentError, '床開口の幅・奥行きは1 mm以上必要です。' if high.zip(low).any? { |u, v| u - v < Layout::MIN_MM }

        [[low[0], low[1]], [high[0], low[1]], [high[0], high[1]], [low[0], high[1]]]
      end

      def perimeter(points)
        points.zip(points.rotate)
      end

      def rings(params, outline)
        rings = params.fetch(KEY, []).map do |opening|
          ring = rectangle(*opening.fetch('corners'))
          a, b = ring.values_at(0, 2)
          margin = Layout::MIN_MM
          padded = rectangle(a.map { |v| v - margin }, b.map { |v| v + margin })
          inside = padded.all? { |point| ColumnCuts.contains?(outline, point) } &&
                   perimeter(padded).none? { |p, q| perimeter(outline).any? { |u, v| Layout.segments_cross?(p, q, u, v) } }
          raise ArgumentError, '床開口は床の外周から離して配置してください。' unless inside

          ring
        end
        rings.combination(2).each do |a, b|
          separate = [0, 1].any? do |axis|
            a[2][axis] + Layout::MIN_MM <= b[0][axis] || b[2][axis] + Layout::MIN_MM <= a[0][axis]
          end
          raise ArgumentError, '床開口同士が重なるか、近すぎます。' unless separate
        end
        rings
      end

      def write(group, outline, holes, bottom, top)
        return API.write_prism(group, outline, bottom, top - bottom) if holes.empty?

        outline = outline.reverse if ColumnCuts.signed_area(outline).negative?
        loops = [outline, *holes.map(&:reverse)]
        at = ->(loop, z) { loop.map { |xy| API.point(*xy, z) } }
        group.entities.build do |builder|
          up = loops.map { |loop| at.call(loop, top) }
          down = loops.map { |loop| at.call(loop.reverse, bottom) }
          builder.add_face(up.first, holes: up.drop(1))
          builder.add_face(down.first, holes: down.drop(1))
          loops.each do |loop|
            perimeter(loop).each do |a, b|
              builder.add_face([API.point(*a, bottom), API.point(*b, bottom), API.point(*b, top), API.point(*a, top)])
            end
          end
        end
        raise ArgumentError, '開口のある床をソリッドにできませんでした。' unless group.manifold? && group.volume.positive?

        group.entities.each { |item| item.layer = group.model.layers[0] }
      end

      def net_area(params)
        outline = Layout.slab_outline(params.fetch('points'))
        ColumnCuts.signed_area(outline).abs - rings(params, outline).sum { |ring| ColumnCuts.signed_area(ring).abs }
      end

      def selected(model)
        slab = model.selection.first
        unless model.selection.one? && slab.is_a?(Sketchup::Group) && Follow.kind(slab) == 'slab'
          raise ArgumentError, '上階の床スラブを1つ選択してください。'
        end
        slab
      end

      def validate_host!(slab)
        raise ArgumentError, '水平な床スラブを選んでください。' unless PlanLinework.upright?(slab.transformation)
        raise ArgumentError, '床のロックを解除してください。' if slab.locked?
      end

      def add(slab, first, last)
        validate_host!(slab)
        local = [first, last].map { |point| point.transform(slab.transformation.inverse).to_a.first(2).map { |v| v.to_mm.round(4) } }
        ring = rectangle(*local)
        params = Follow.parameters(slab)
        opening = { 'id' => SecureRandom.uuid, 'corners' => ring.values_at(0, 2) }
        params[KEY] = params.fetch(KEY, []) + [opening]
        API.regenerate(slab, params, refresh_plan: true)
        opening
      end

      def options(params)
        params.fetch(KEY, []).map.with_index do |opening, index|
          a, b = opening.fetch('corners')
          dimensions = b.zip(a).map { |end_at, start| format('%g', end_at - start) }.join('×')
          ["開口 #{index + 1}　#{dimensions} mm", opening]
        end.to_h
      end

      def draw_plan(entities, model, level, cut, hidden)
        model.entities.grep(Sketchup::Group).sum do |slab|
          next 0 unless Follow.kind(slab) == 'slab' && !hidden.include?(slab.persistent_id) && slab.layer.visible?

          params = Follow.parameters(slab)
          top = slab.transformation.origin.z.to_mm
          floor = API.levels(model).fetch(level)
          assigned = params['level']
          next 0 if top > cut || (assigned ? assigned != level : (top - floor).abs > 1)

          openings = params.fetch(KEY, [])
          openings.each do |opening|
            ring = rectangle(*opening.fetch('corners')).map do |xy|
              API.point(*xy).transform(slab.transformation).tap { |point| point.z = (cut - 0.35).mm }
            end
            perimeter(ring).each { |a, b| entities.add_line(a, b) }
            entities.add_text('開口', Geom.linear_combination(0.7, ring.first, 0.3, ring[2]))
          end
          openings.size
        end
      end

      def edit(slab)
        validate_host!(slab)
        params = Follow.parameters(slab)
        choices = options(params)
        raise ArgumentError, 'この床に開口はありません。' if choices.empty?

        selected = UI.inputbox(['床開口', '操作'], [choices.keys.first, '位置・寸法を変更'],
                               [choices.keys.join('|'), '位置・寸法を変更|削除'], '床開口を編集')
        return unless selected

        opening = choices.fetch(selected.first)
        if selected.last == '削除'
          if Stairs.linked?(slab, opening.fetch('id'))
            raise ArgumentError, 'この開口に直階段があります。先に階段を削除してください。'
          end
          params[KEY].delete(opening)
        else
          a, b = opening.fetch('corners')
          fields = ['床原点から X (mm)', '床原点から Y (mm)', 'X方向の幅 (mm)', 'Y方向の奥行き (mm)']
          inputs = UI.inputbox(fields, [*a, b[0] - a[0], b[1] - a[1]], '床開口の位置・寸法')
          return unless inputs

          x, y, width, depth = fields.zip(inputs).map.with_index { |(label, value), i| Layout.mm(value, label, positive: i >= 2) }
          opening['corners'] = [[x, y], [x + width, y + depth]]
        end
        API.regenerate(slab, params, refresh_plan: true)
      end
    end
  end
end
