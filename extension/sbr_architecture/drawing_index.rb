# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module DrawingIndex
      HEADINGS = %w[図番 図面名 縮尺 掲載シート 位置 ページ].freeze
      WIDTHS = [34, 192, 35, 53, 43, 35].freeze
      module_function

      def positions(placements)
        return [''] if placements.one?

        xs = placements.map { |_, frame, _| frame[0] }.uniq.sort
        ys = placements.map { |_, frame, _| frame[1] }.uniq.sort
        placements.map do |_, (x, y, _width, _height), _|
          row = %w[上 下][ys.index(y)] if ys.size > 1
          column = %w[左 右][xs.index(x)] if xs.size > 1
          "#{column}#{row}"
        end
      end

      def rows(sheets, schedules)
        drawing_rows = sheets.each_with_index.flat_map do |sheet, index|
          sheet.placements.zip(positions(sheet.placements)).map do |((scene, spec, scale), _, _), position|
            [LayoutSheets.drawing_number(scene), Drawings.title(spec), "1:#{scale}", sheet.number, position, index + 1]
          end
        end
        table_numbers = DrawingSchedules::TABLES.values.map(&:first)
        table_rows = schedules.each_with_index.filter_map do |(number, title), index|
          [number, title, '', number, '', sheets.size + index + 1] if table_numbers.include?(number)
        end
        drawing_rows + table_rows
      end

      def pages(sheets, schedules)
        values = rows(sheets, schedules)
        count = DrawingSchedules.paginate(values, WIDTHS).size
        # The page column is wide enough for the folio and its front-matter
        # offset. Adding the index pages doesn't change the row heights.
        numbered = values.map { |row| [*row.first(5), row.last + count] }
        drawing_count = sheets.sum { |sheet| sheet.placements.size }
        summary = "図面 #{drawing_count}図　　参照図番から掲載シートとページを確認できます。"
        DrawingSchedules.paginate(numbered, WIDTHS).map.with_index(1) do |part, page|
          title = page == 1 ? '図面目録' : "図面目録（#{page}）"
          [format('I-%02d', page), title, summary, HEADINGS, WIDTHS, part]
        end
      end
    end
  end
end
