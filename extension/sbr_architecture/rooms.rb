# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Rooms
      API = SbrArchitecture
      module_function

      def items(model)
        model.entities.grep(Sketchup::Group).select { |item| Follow.kind(item) == 'room' }
      end

      def world_loop(points, transform)
        points.map { |xy| API.point(*xy).transform(transform).to_a.first(2).map { |value| value.to_mm.round(3) } }
      end

      def boundaries(model, level)
        floor = API.levels(model)[level]
        return unless floor

        wall_z = floor + 10
        walls, voids = [], []
        model.entities.grep(Sketchup::Group).each do |item|
          kind = Follow.kind(item)
          next unless %w[wall slab].include?(kind) && PlanLinework.upright?(item.transformation)

          params = Follow.parameters(item)
          if kind == 'wall'
            box = item.bounds
            next unless box.valid? && box.min.z.to_mm <= wall_z && box.max.z.to_mm > wall_z

            walls.concat(API.wall_profiles(params).map { |loop| world_loop(loop, item.transformation) })
          elsif params['level'] == level || (!params['level'] && (item.transformation.origin.z.to_mm - floor).abs <= 1)
            params.fetch(SlabOpenings::KEY, []).each do |opening|
              voids << world_loop(SlabOpenings.rectangle(*opening.fetch('corners')), item.transformation)
            end
          end
        end
        RoomBoundaries.new(walls, voids.uniq)
      end

      def room_name(value)
        name = value.to_s.strip
        raise ArgumentError, '室名を1〜30文字で入力してください。' if name.empty? || name.length > 30 || name.match?(/[[:cntrl:]]/)

        name
      end

      def write(item, params, floor)
        item.make_unique
        raise ArgumentError, '室の表示を更新できませんでした。' unless item.entities.clear!

        item.name = "室｜#{params.fetch('room_name')}"
        item.entities.add_text(params.fetch('room_name'), ORIGIN)
        item.transformation = Geom::Transformation.translation(API.point(*params.fetch('seed'), floor))
        API.store_params(item, 'room', params)
      end

      def measured_area(layout, region)
        return unless region

        area = layout.area(region) / 1e6
        area.round(5) if area.positive?
      end

      def dialog(model, level, seed, room = nil)
        layout = boundaries(model, level)
        region = layout&.region_at(seed)
        area = measured_area(layout, region)
        raise ArgumentError, '壁の内側で、閉じた室の床をクリックしてください。' unless area

        unless room
          matches = items(model).select do |item|
            params = Follow.parameters(item)
            params['level'] == level && layout.region_at(params['seed']).equal?(region)
          end
          raise ArgumentError, 'この範囲に室が複数あります。3D作業ビューで室を選び直してください。' if matches.size > 1

          room = matches.first
        end
        old = room ? Follow.parameters(room) : {}
        input = UI.inputbox(['室名'], [old.fetch('room_name', '室')], "室の設定｜#{format('%.2f', area)} m²")
        return unless input

        params = { 'room_name' => room_name(input.first), 'seed' => seed, 'level' => level, 'area' => area }
        updated = nil
        API.operation(model, room ? '室情報を更新' : '室を登録') do
          raise ArgumentError, '室のロックを解除してください。' if room&.locked?

          room ||= model.entities.add_group
          write(room, params, API.levels(model).fetch(level))
          if (plan = Openings::PlanPick.active_spec(model)) && plan['level'] == level
            updated = Drawings.generate(model, [plan], within_operation: true).first
          end
        end
        Drawings.open_page(model, updated) if updated
        room
      end

      def edit(room)
        params = Follow.parameters(room)
        dialog(room.model, params.fetch('level'), params.fetch('seed'), room)
      end

      def refresh(model)
        items(model).group_by { |room| Follow.parameters(room)['level'] }.each do |level, rooms|
          layout = boundaries(model, level)
          floor = API.levels(model)[level]
          by_region = rooms.group_by { |room| layout&.region_at(Follow.parameters(room).fetch('seed')) }
          by_region.each do |region, group|
            area = group.one? ? measured_area(layout, region) : nil
            group.each do |room|
              params = Follow.parameters(room)
              if params['area'] != area
                raise ArgumentError, '面積を更新するには室のロックを解除してください。' if room.locked?

                API.store_params(room, 'room', params.merge('area' => area))
              end
              if floor && (room.transformation.origin.z.to_mm - floor).abs > 0.001
                raise ArgumentError, '室の高さを更新するにはロックを解除してください。' if room.locked?

                room.transformation = Geom::Transformation.translation(API.point(*params.fetch('seed'), floor))
              end
            end
          end
        end
      end

      def draw_plan(entities, model, level, cut, denominator, hidden)
        items(model).filter_map do |room|
          params = Follow.parameters(room)
          next unless params['level'] == level && !hidden.include?(room.persistent_id) && room.layer.visible?

          x, y = params.fetch('seed')
          area = params['area'] ? format('%.2f m²', params['area']) : '室境界を確認'
          name = params.fetch('room_name')
          entities.add_text(name, API.point(x, y, cut - 0.35))
          entities.add_text(area, API.point(x, y - 4.2 * denominator, cut - 0.35))
          width = [name, area].map { |label| label.each_char.sum { |char| char.ascii_only? ? 2.4 : 4.2 } }.max
          left, right = x - denominator, x + (width + 1) * denominator
          low, high = y - 6.7 * denominator, y + 2.7 * denominator
          ColumnCuts.mask_for([[[left, low], [right, low], [right, high], [left, high]]])
        end
      end
    end
  end
end
