# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module LayoutScheduleUpdate
      META = LayoutSheets::SCHEDULE_META
      Entry = Struct.new(:number, :type, :page, :body)
      module_function

      def available?
        defined?(::Layout::Document) && ::Layout::Document.method_defined?(:set_attribute)
      end

      def check_model!(model)
        raise ArgumentError, '表の更新にはLayOut 2026以降が必要です。' unless available?
        if model.path.empty? || model.modified? || !File.file?(model.path)
          raise ArgumentError, '「モデルから全更新」を実行し、SKPを保存してから表を更新してください。'
        end
      end

      def table_type(number)
        DrawingSchedules::TABLES.find do |_, (prefix, *)|
          number.match?(/\A#{prefix}(?:-\d{2,})?\z/)
        end&.first
      end

      def entries(doc)
        sheets = doc.pages.filter_map do |page|
          number = page.get_attribute(META, 'sheet')
          if number
            type = table_type(number)
            body = tagged_body(page)
            unless type && body
              raise ArgumentError, "「#{page.name}」の表または集計欄を特定できません。表が編集・移動されていないか確認してください。"
            end
            Entry.new(number, type, page, body)
          else
            legacy_entry(page)
          end
        end
        if sheets.map(&:number).uniq.size != sheets.size
          raise ArgumentError, '同じ表の図番を持つページが複数あります。更新するLayOutを確認してください。'
        end

        sheets
      end

      def tagged_body(page)
        entities = page.nonshared_entities.to_a
        tables = entities.grep(::Layout::Table).select { |item| item.get_attribute(META, 'role') == 'table' }
        summaries = entities.grep(::Layout::FormattedText).select { |item| item.get_attribute(META, 'role') == 'summary' }
        { 'table' => tables.first, 'summary' => summaries.first } if tables.one? && summaries.one?
      end

      def legacy_entry(page)
        DrawingSchedules::TABLES.each do |type, (prefix, title, headings, _)|
          match = /\A#{title}(?:（(\d+)）)?\z/.match(page.name)
          next unless match

          entities = page.nonshared_entities.select do |item|
            item.layer_instance&.definition&.name == LayoutSheets::SCHEDULE_LAYER
          end
          next if entities.empty?

          number = match[1] ? "#{prefix}-#{format('%02d', match[1].to_i)}" : prefix
          tables = entities.grep(::Layout::Table).select do |table|
            table.dimensions.last == headings.size &&
              headings.each_with_index.all? { |heading, index| table[0, index].data.plain_text == heading }
          end
          texts = entities.grep(::Layout::FormattedText)
          generated_title = texts.any? { |text| text.plain_text == "#{number}    #{page.name}" }
          summary_start = type == 'openings' ? /\A開口寸法は幅・高さとも mm/ : /\A室 \d+件　　面積集計/
          summaries = texts.select { |text| text.plain_text.match?(summary_start) }
          unless tables.one? && generated_title && summaries.one?
            raise ArgumentError, "「#{page.name}」の旧版の表を特定できません。図番の見出し・列見出し・集計欄を確認してください。"
          end
          return Entry.new(number, type, page, { 'table' => tables.first, 'summary' => summaries.first })
        end
        nil
      end

      def replace_body(doc, entry, sheet)
        replacements = LayoutSheets.schedule_body(sheet)
        entry.body.each do |role, original|
          instance = original.layer_instance
          layer = instance.definition
          index = instance.entity_index(original)
          doc.remove_entity(original)
          added = doc.add_entity(replacements.fetch(role), layer, entry.page)
          instance.reorder_entity(added, index)
        end
        entry.page.set_attribute(META, 'sheet', entry.number)
      end

      def retired_sheet(entry)
        prefix, _, headings, widths = DrawingSchedules::TABLES.fetch(entry.type)
        rows = DrawingSchedules.paginate([['続きなし', *Array.new(widths.size - 1, '')]], widths).first
        [entry.number, entry.page.name, "このページに続く行はありません。最新の一覧は #{prefix} からご覧ください。",
         headings, widths, rows]
      end

      def update_document(doc, model)
        expected = doc.get_attribute(META, 'source')
        if expected && (!File.file?(expected) || !File.identical?(expected, model.path))
          raise ArgumentError, 'このLayOutを出力したSKPと、開いているSKPが異なります。元のSKPを開いてください。'
        end
        unless (doc.page_info.width.to_mm - 420).abs < 0.2 && (doc.page_info.height.to_mm - 297).abs < 0.2
          raise ArgumentError, '更新できるのは、この拡張で出力したA3横の表です。'
        end

        existing = entries(doc)
        raise ArgumentError, '更新対象の建具表・室一覧がありません。先に表を付けてLayOutへ配置してください。' if existing.empty?
        if existing.any? { |entry| entry.body.values.any? { |item| item.locked? || item.layer_instance.definition.locked? } }
          raise ArgumentError, '表または集計欄がロックされています。LayOutでロックを解除し、保存してください。'
        end

        types = existing.map(&:type).uniq
        LayoutSheets.check_rooms!(model) if types.include?('rooms')
        latest = DrawingSchedules.pages(model, types).to_h { |sheet| [sheet.first, sheet] }
        retired = 0
        existing.each do |entry|
          sheet = latest.delete(entry.number)
          retired += 1 unless sheet
          replace_body(doc, entry, sheet || retired_sheet(entry))
        end
        unless latest.empty?
          layer = doc.layers.find { |item| item.name == LayoutSheets::SCHEDULE_LAYER }
          layer ||= doc.layers.add(LayoutSheets::SCHEDULE_LAYER, false)
          latest.each_value { |sheet| LayoutSheets.schedule_sheet(doc, layer, sheet) }
        end
        doc.set_attribute(META, 'source', File.expand_path(model.path))
        { updated: existing.size - retired, added: latest.size, retired: retired, legacy: expected.nil? }
      end

      def save_copy(model, source, destination)
        check_model!(model)
        destination = "#{destination}.layout" unless File.extname(destination).casecmp?('.layout')
        raise ArgumentError, '更新元のLayOutが見つかりません。' unless File.file?(source)
        raise ArgumentError, '参照先を保つため、更新元と同じフォルダに保存してください。' unless File.identical?(File.dirname(source), File.dirname(destination))
        raise ArgumentError, '元のファイルを残すため、新しいファイル名を指定してください。' if File.exist?(destination)

        doc = ::Layout::Document.open(source)
        result = update_document(doc, model)
        doc.save(destination)
        raise ArgumentError, '更新したLayOutを保存できませんでした。' unless File.file?(destination)

        result
      end
    end
  end
end
