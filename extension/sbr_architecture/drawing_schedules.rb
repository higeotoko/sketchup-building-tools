# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module DrawingSchedules
      API = SbrArchitecture
      TABLES = {
        'openings' => ['T-01', '建具表', ['階', '建具記号', '種別', '形式', '幅 mm', '高さ mm', '腰高 mm', '数量', '仕様・備考'],
                       [34, 34, 24, 46, 25, 25, 25, 20, 159]],
        'rooms' => ['T-02', '室一覧', ['階', '室名', '面積 m²', '備考'], [42, 190, 51, 109]]
      }.freeze
      TOP = 48
      BOTTOM = 263
      LINE_HEIGHT = 4.2
      PADDING = 3
      module_function

      def level_order(levels, level)
        [levels.fetch(level, Float::INFINITY), level]
      end

      def opening_spec(item)
        if item['kind'] == 'window'
          mount = Openings.window_mount(item)
          position = Openings::WINDOW_MOUNTS.fetch(mount.fetch('mode'))
          position += " #{format('%g', mount['offset'])} mm" if mount['offset'].positive?
          side = Openings::EXTERIOR_SIDES.fetch(mount.fetch('side'))
          hinge = if Openings::HANDED_WINDOWS.include?(Openings.window_type(item))
                    item.fetch('hinge', 'start') == 'start' ? '可動側 始点側' : '可動側 終点側'
                  end
          [position, side, hinge, item.dig('sash', 'product_id')].compact.join(' / ')
        else
          direction = Doors.direction(item)
          motion = Doors.direction_options(Doors.type(item))[direction]
          width = "子扉 #{format('%g', item['inactive_width'])} mm" if item['inactive_width']
          [motion, width].compact.join(' / ')
        end
      end

      def opening_rows(model, levels)
        records = model.entities.grep(Sketchup::Group).flat_map do |wall|
          next [] unless Follow.kind(wall) == 'wall'

          params = Follow.parameters(wall)
          params.fetch('openings', []).map do |item|
            window = item['kind'] == 'window'
            dimensions = item.values_at('width', 'height').map { |value| format('%g', value) }
            sill = format('%g', item.fetch('sill', 0)) if window
            mark = item['mark'].to_s.strip
            [params['level'] || '未指定', mark, window ? '窓' : '扉', Openings.label(item),
             *dimensions, sill.to_s, opening_spec(item)]
          end
        end
        conflicts = records.reject { |row| row[1].empty? }.group_by { |row| row[1] }
                           .select { |_, rows| rows.map { |row| row.drop(2) }.uniq.size > 1 }
        rows = records.tally.map do |row, count|
          level, mark, type, form, width, height, sill, spec = row
          spec = [spec, '同じ記号に異なる仕様あり'].reject(&:empty?).join(' / ') if conflicts.key?(mark)
          [level, mark.empty? ? '未入力' : mark, type, form, width, height, sill, count.to_s, spec]
        end.sort_by { |row| [*level_order(levels, row[0]), row[1], row[2], row[3], row[4].to_f, row[5].to_f, row.last] }
        [rows, "開口寸法は幅・高さとも mm　　窓・扉 合計 #{records.size}箇所"]
      end

      def room_rows(model, levels)
        rooms = Rooms.items(model).map { |room| Follow.parameters(room) }
        rooms.sort_by! { |room| [*level_order(levels, room['level'] || '未指定'), room.fetch('room_name')] }
        rows = rooms.map do |room|
          area = room['area']
          [room['level'] || '未指定', room.fetch('room_name'), area ? format('%.2f', area) : '', area ? '' : '室境界を確認']
        end
        total = rows.sum { |row| row[2].to_f }
        unresolved = rows.count { |row| row[2].empty? }
        note = format('室 %d件　　面積集計 %.2f m²', rows.size, total)
        note += "　　未確定 #{unresolved}件（面積集計から除外）" if unresolved.positive?
        [rows, note]
      end

      def wrap(value, width)
        lines = [+'']
        occupied = 0.0
        value.to_s.gsub(/[[:cntrl:]]/, ' ').strip.each_char do |char|
          advance = char.ascii_only? ? 2.8 : 3.6
          if occupied + advance > width - 2 * PADDING
            lines << +''
            occupied = 0.0
          end
          lines.last << char
          occupied += advance
        end
        lines
      end

      def paginate(rows, widths)
        rows = [['登録なし', *Array.new(widths.size - 1, '')]] if rows.empty?
        pages = [[]]
        cursor = TOP
        max_lines = ((BOTTOM - TOP - 4) / LINE_HEIGHT).floor
        rows.each do |row|
          cells = row.zip(widths).map { |value, width| wrap(value, width) }
          cells.map(&:size).max.times.each_slice(max_lines) do |indices|
            height = 4 + LINE_HEIGHT * indices.size
            if cursor + height > BOTTOM
              pages << []
              cursor = TOP
            end
            pages.last << [cursor, height, cells.map { |lines| lines[indices.first, indices.size] || [] }]
            cursor += height
          end
        end
        pages
      end

      def pages(model, types)
        raise ArgumentError, '建具表と室一覧の出力設定を確認してください。' unless types.is_a?(Array) && (types - TABLES.keys).empty?
        return [] if types.empty?

        levels = API.levels(model)
        TABLES.filter_map do |type, (number, title, headings, widths)|
          next unless types.include?(type)

          rows, note = type == 'openings' ? opening_rows(model, levels) : room_rows(model, levels)
          parts = paginate(rows, widths)
          parts.each_with_index.map do |part, index|
            suffix = index.zero? ? '' : format('-%02d', index + 1)
            name = index.zero? ? title : "#{title}（#{index + 1}）"
            [number + suffix, name, note, headings, widths, part]
          end
        end.flatten(1)
      end
    end
  end
end
