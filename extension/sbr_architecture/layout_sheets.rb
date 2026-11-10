# frozen_string_literal: true

require 'date'

module Higeotoko
  module SbrArchitecture
    module LayoutSheets
      SCALES = [20, 25, 50, 100, 200, 500, 1000].freeze
      AUTO_SCALES = SCALES.drop(2).freeze
      VIEWPORT_MM = [14, 29, 392, 244].freeze
      ARRANGEMENTS = %w[single grouped].freeze
      GROUP_NAMES = { 'plan' => '一般平面図', 'framing' => '梁伏図', 'elevation' => '立面図', 'section' => '断面図' }.freeze
      PANEL_GAP_MM = 8
      PANEL_WIDTH_MARGIN_MM = 20
      PANEL_HEIGHT_MARGIN_MM = 12
      CAPTION_MM = 9
      PROJECT_FIELDS = {
        'name' => ['案件名', 36], 'number' => ['案件番号', 14], 'author' => ['作成者', 16], 'date' => ['発行日', 10]
      }.freeze
      TITLE_COLUMNS = [10, 162, 217, 278, 333, 410].freeze
      SCHEDULE_LAYER = '建具表・室一覧'
      SCHEDULE_META = 'higeotoko.sbr_architecture.layout_schedule'
      module_function

      def check_source!(model, keys: nil, tables: [], allow_missing_sections: false)
        raise ArgumentError, 'このSketchUp環境ではLayOutへの配置を利用できません。' unless defined?(::Layout::Document)
        all = Drawings.specs(model)
        raise ArgumentError, '先に図面シーンを作成してください。' if all.empty?
        scenes = keys.nil? ? all : PublicationSets.drawing_subset(all, keys)
        if scenes.any? { |scene, _| JSON.parse(scene.get_attribute(Drawings::META, 'stats', '{}'))['provisional'] }
          raise ArgumentError, '仮の図面があります。建築モデルを作図し、「モデルから全更新」してから配置してください。'
        end
        numbers = all.to_h { |scene, spec| [spec.fetch('key'), scene.get_attribute(Drawings::META, 'sheet_number')] }
        references = Drawings.section_references(Drawings.section_targets(all.map(&:last), numbers))
        if scenes.any? { |scene, spec| needs_update?(scene, spec, numbers, references) }
          raise ArgumentError, '「モデルから全更新」で図面を更新し、SKPを保存してください。'
        end
        if model.path.empty? || model.modified? || !File.file?(model.path)
          raise ArgumentError, '図面シーンを更新したSKPを保存してから配置してください。'
        end
        signature = Drawings.source_signature(model)
        stale = scenes.filter_map do |scene, _|
          scene.name if scene.get_attribute(Drawings::META, 'source_signature') != signature
        end
        if stale.any?
          raise ArgumentError, "更新が必要な図面があります（#{brief_list(stale)}）。「モデルから全更新」してSKPを保存してください。"
        end
        check_rooms!(model, signature) if tables.include?('rooms')
        unless allow_missing_sections
          missing = missing_section_labels(all, scenes, numbers)
          if missing.any?
            raise ArgumentError, "平面が参照する断面が発行対象外です（#{brief_list(missing)}）。セットに追加するか、対象外を許可してください。"
          end
        end
        scenes
      end

      def brief_list(items)
        text = items.first(4).join('、')
        items.size > 4 ? "#{text} ほか#{items.size - 4}件" : text
      end

      def check_rooms!(model, signature = Drawings.source_signature(model))
        return if Rooms.items(model).empty? || model.get_attribute(Drawings::META, 'room_schedule_signature') == signature

        raise ArgumentError, '室一覧の面積が古い可能性があります。「モデルから全更新」してSKPを保存してください。'
      end

      def missing_section_labels(all, scenes, numbers)
        chosen = scenes.map { |_, data| data.fetch('key') }
        targets = scenes.filter_map do |scene, data|
          scene.get_attribute(Drawings::META, 'drawn_section_keys', []) if data['kind'] == 'plan'
        end.flatten.uniq - chosen
        all.filter_map do |_, data|
          key = data.fetch('key')
          "#{Drawings.sheet_label(numbers[key])} #{Drawings.title(data)}" if targets.include?(key)
        end
      end

      def needs_update?(scene, spec, numbers, references)
        !numbers[spec.fetch('key')] || !scene.get_attribute(Drawings::META, 'paper_scale') ||
          !scene.get_attribute(Drawings::META, 'extent_mm') ||
          (spec['kind'] == 'plan' && Drawings.plan_needs_update?(scene, references))
      end

      def sheet_bounds(x, y, width, height)
        Geom::Bounds2d.new(x.mm.to_f, y.mm.to_f, width.mm.to_f, height.mm.to_f)
      end

      def millimeter_dimensions?(model)
        units = model.options['UnitsOptions']
        units['LengthUnit'] == Length::Millimeter && units['LengthFormat'] == Length::Decimal
      end

      def fitting_scale(extent, requested)
        width, height = extent
        _, _, frame_width, frame_height = VIEWPORT_MM
        candidates = requested ? [requested] : AUTO_SCALES
        candidates.find { |number| width / number <= frame_width - 20 && height / number <= frame_height - 20 }
      end

      def paper_scale(scene, requested)
        authored = scene.get_attribute(Drawings::META, 'paper_scale')
        scale = fitting_scale(scene.get_attribute(Drawings::META, 'extent_mm'), requested || authored)
        raise ArgumentError, "「#{scene.name}」がA3に収まりません。縮尺を小さくして図面を更新してください。" unless scale
        if authored && scale != authored
          raise ArgumentError, "「#{scene.name}」の注記は1:#{authored}です。1:#{scale}で「モデルから全更新」を実行し、SKPを保存してください。"
        end

        scale
      end

      def viewport_line_weight(denominator)
        return 0.25 if denominator >= 100
        return 0.35 if denominator >= 50

        0.5
      end

      def paper_extent(entry)
        scene, _, denominator = entry
        scene.get_attribute(Drawings::META, 'extent_mm').map { |length| length / denominator.to_f }
      end

      def group_placements(entries, columns, rows)
        x, y, width, height = VIEWPORT_MM
        slot_width = (width - (columns - 1) * PANEL_GAP_MM).to_f / columns
        slot_height = (height - (rows - 1) * PANEL_GAP_MM).to_f / rows
        extents = entries.map { |entry| paper_extent(entry) }
        return if extents.any? do |w, h|
          w + PANEL_WIDTH_MARGIN_MM > slot_width || h + PANEL_HEIGHT_MARGIN_MM + CAPTION_MM > slot_height
        end

        entries.each_slice(columns).with_index.flat_map do |row, index|
          content_height = extents.slice(index * columns, row.size).map(&:last).max + PANEL_HEIGHT_MARGIN_MM
          top = y + index * (slot_height + PANEL_GAP_MM) + (slot_height - content_height - CAPTION_MM) / 2
          row.each_with_index.map do |entry, column|
            left = x + column * (slot_width + PANEL_GAP_MM)
            [entry, [left, top + CAPTION_MM, slot_width, content_height], [left, top, slot_width, CAPTION_MM - 2]]
          end
        end
      end

      def arrange(entries, mode)
        raise ArgumentError, 'LayOutの配置方法を選んでください。' unless ARRANGEMENTS.include?(mode)

        groups = if mode == 'grouped'
                   entries.group_by { |_, spec, denominator| [spec.fetch('kind'), denominator] }.values
                 else
                   entries.map { |entry| [entry] }
                 end
        groups.flat_map do |remaining|
          sheets = []
          until remaining.empty?
            kind = remaining.first[1].fetch('kind')
            placements = nil
            if kind == 'elevation' && remaining.size >= 3
              placements = group_placements(remaining.first(4), 2, 2) ||
                           group_placements(remaining.first(3), 2, 2)
            end
            if !placements && remaining.size >= 2
              pair = remaining.first(2)
              placements = group_placements(pair, 2, 1) || group_placements(pair, 1, 2)
            end
            placements ||= [[remaining.first, VIEWPORT_MM, nil]]
            sheets << placements
            remaining = remaining.drop(placements.size)
          end
          sheets
        end
      end

      def project_fields(values, model_title)
        fields = PROJECT_FIELDS.to_h do |key, (label, limit)|
          text = values.fetch(key, '').to_s.strip
          if text.length > limit || text.match?(/[[:cntrl:]]/)
            raise ArgumentError, "#{label}は#{limit}文字以内の1行で入力してください。"
          end
          [key, text]
        end
        fields['name'] = model_title.to_s.strip.gsub(/[[:cntrl:]]/, ' ')[0, PROJECT_FIELDS.fetch('name').last] if fields['name'].empty?
        unless fields['date'].empty?
          date = fields.fetch('date')
          begin
            raise ArgumentError unless /\A\d{4}-\d{2}-\d{2}\z/.match?(date)

            Date.iso8601(date)
          rescue ArgumentError
            raise ArgumentError, '発行日は年月日を正しく入力してください。'
          end
        end
        fields
      end

      def styled_rule(entity, weight)
        style = entity.style
        style.solid_filled = false
        style.stroked = true
        style.stroke_width = weight
        style.stroke_color = Sketchup::Color.new(35, 35, 35)
        entity.style = style
        entity
      end

      def line(x1, y1, x2, y2)
        points = [[x1, y1], [x2, y2]].map { |x, y| Geom::Point2d.new(x.mm.to_f, y.mm.to_f) }
        styled_rule(::Layout::Path.new(*points), 0.4)
      end

      def text(value, bounds, size, bold: false)
        entity = ::Layout::FormattedText.new(value.empty? ? '—' : value, sheet_bounds(*bounds))
        style = entity.style(0)
        style.font_size = size
        style.text_bold = bold
        entity.apply_style(style)
        entity
      end

      def title_cell(doc, layer, column, label, value, page = nil)
        left, right = TITLE_COLUMNS.values_at(column, column + 1)
        width = right - left - 6
        items = [text(label, [left + 3, 274, width, 4.4], 7.5),
                 text(value, [left + 3, 279, width, 6.5], 10)]
        items.each { |item| page ? doc.add_entity(item, layer, page) : doc.add_entity(item, layer) }
      end

      def shared_frame(doc, project)
        layer = doc.layers.add('図枠・案件欄', true)
        frame = ::Layout::Rectangle.new(sheet_bounds(10, 10, 400, 277))
        doc.add_entity(styled_rule(frame, 0.7), layer)
        [27, 273].each { |y| doc.add_entity(line(10, y, 410, y), layer) }
        TITLE_COLUMNS[1...-1].each { |x| doc.add_entity(line(x, 273, x, 287), layer) }
        PROJECT_FIELDS.each_with_index do |(key, (label, _)), column|
          title_cell(doc, layer, column, label, project.fetch(key))
        end
      end

      def schedule_sheet(doc, layer, sheet)
        number, title = sheet
        page = doc.pages.add(title)
        page.set_attribute(SCHEDULE_META, 'sheet', number) if page.respond_to?(:set_attribute)
        doc.add_entity(text("#{number}    #{title}", [14, 13, 392, 11], 14, bold: true), layer, page)
        title_cell(doc, layer, 4, '縮尺・用紙', '縮尺なし (A3)', page)
        schedule_body(sheet).each { |_, entity| doc.add_entity(entity, layer, page) }
        page
      end

      def schedule_body(sheet)
        _, _, note, headings, widths, rows = sheet
        top = DrawingSchedules::TOP
        bottom = rows.last[0] + rows.last[1]
        table = ::Layout::Table.new(sheet_bounds(14, top - 9, widths.sum, bottom - top + 9), rows.size + 1, widths.size)
        widths.each_with_index { |width, index| table.get_column(index).width = width.mm.to_f }
        table.get_row(0).height = 9.mm.to_f
        rows.each_with_index { |(_, height, _), index| table.get_row(index + 1).height = height.mm.to_f }
        cells = [headings, *rows.map { |_, _, columns| columns.map { |lines| lines.join("\n") } }]
        cells.each_with_index do |values, row|
          values.each_with_index do |value, column|
            next if value.empty?

            table[row, column].data = text(value, [0, 0, widths[column], 9], 9, bold: row.zero?)
          end
        end
        { 'summary' => text(note, [14, 30, 392, 6], 10), 'table' => table }.each do |role, entity|
          entity.set_attribute(SCHEDULE_META, 'role', role) if entity.respond_to?(:set_attribute)
        end
      end

      def viewport(model, scene_index, denominator, bounds)
        entity = ::Layout::SketchUpModel.new(model.path, sheet_bounds(*bounds))
        entity.current_scene = scene_index
        entity.render_mode = ::Layout::SketchUpModel::HYBRID_RENDER
        entity.display_background = false
        entity.line_weight = viewport_line_weight(denominator)
        entity.scale = 1.0 / denominator
        entity.preserve_scale_on_resize = true
        entity
      end

      def export(model, file, scale: nil, project: {}, tables: [], arrangement: 'single', keys: nil, allow_missing_sections: false)
        scenes = check_source!(model, keys: keys, tables: tables, allow_missing_sections: allow_missing_sections)
        project = project_fields(project, model.title)
        raise ArgumentError, '対応する縮尺を選んでください。' if scale && !SCALES.include?(scale)
        file = "#{file}.layout" unless File.extname(file).casecmp?('.layout')
        if File.exist?(file)
          raise ArgumentError, '新しいファイル名で保存してください。既存LayOutのビューポートは参照更新で更新できます。'
        end

        schedules = DrawingSchedules.pages(model, tables)
        entries = scenes.map { |scene, spec| [scene, spec, paper_scale(scene, scale)] }
        sheets = arrange(entries, arrangement)
        doc = ::Layout::Document.new
        doc.page_info.width = 420.mm.to_f
        doc.page_info.height = 297.mm.to_f
        layer = doc.layers[0]
        shared_frame(doc, project)
        unit_note = millimeter_dimensions?(model) ? '寸法 mm' : 'レベル mm'
        scene_indices = model.pages.to_a.each_with_index.to_h { |page, index| [page.persistent_id, index + 1] }
        groups = 0
        sheets.each_with_index do |placements, i|
          scene, spec, denominator = placements.first.first
          if placements.one?
            title = Drawings.title(spec)
            sheet_number = Drawings.sheet_label(scene.get_attribute(Drawings::META, 'sheet_number'))
            page_name = title
          else
            groups += 1
            title = GROUP_NAMES.fetch(spec.fetch('kind'))
            sheet_number = format('M-%02d', groups)
            page_name = "#{sheet_number}｜#{title}"
          end
          page = i.zero? ? doc.pages[0] : doc.pages.add(title)
          page.name = page_name
          placements.each do |(view_scene, view_spec, view_scale), frame, caption|
            view = viewport(model, scene_indices.fetch(view_scene.persistent_id), view_scale, frame)
            doc.add_entity(view, layer, page)
            view.render if view.render_needed?
            if caption
              number = Drawings.sheet_label(view_scene.get_attribute(Drawings::META, 'sheet_number'))
              doc.add_entity(text("#{number}   #{Drawings.title(view_spec)}   1:#{view_scale}", caption, 10, bold: true), layer, page)
              left, top, width, height = caption
              doc.add_entity(line(left, top + height, left + width, top + height), layer, page)
            end
          end
          doc.add_entity(text("#{sheet_number}    #{title}", [14, 13, 392, 11], 14, bold: true), layer, page)
          title_cell(doc, layer, 4, '縮尺・用紙', "1:#{denominator} (A3)   #{unit_note}", page)
        end
        unless schedules.empty?
          schedule_layer = doc.layers.add(SCHEDULE_LAYER, false)
          schedules.each { |sheet| schedule_sheet(doc, schedule_layer, sheet) }
          doc.set_attribute(SCHEDULE_META, 'source', File.expand_path(model.path)) if doc.respond_to?(:set_attribute)
        end
        doc.save(file)
        raise ArgumentError, 'LayOutファイルを保存できませんでした。' unless File.file?(file)

        sheets.size + schedules.size
      end
    end
  end
end
