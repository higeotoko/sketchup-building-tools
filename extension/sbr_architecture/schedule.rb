# frozen_string_literal: true

require 'csv'

module Higeotoko
  module SbrArchitecture
    module Schedule
      API = SbrArchitecture
      HEADERS = %w[階 種別 名称 構造・仕様 幅_mm 高さ・せい_mm 腰高_mm 体積_m3 親壁ID 要素ID].freeze
      module_function

      def rows(model)
        model.entities.grep(Sketchup::Group).flat_map do |group|
          kind = group.get_attribute(API::DICT, 'kind')
          next [] unless Palette::TOOLS.key?(kind) || kind == 'sill'

          params = JSON.parse(group.get_attribute(API::DICT, 'parameters'))
          id = group.persistent_id.to_s
          level = params['level'] || '未指定'
          quantity = volume(group, kind)
          spec = [Catalog::SYSTEMS[params['system']], params['section_id']].compact.join(' ')
          height = kind == 'wall' ? WallHeads.overall_height(params) : (params['height'] || params['depth'])
          base = [level, API.object_name(kind), group.name, spec,
                  params['width'] || params['thickness'], height, nil, quantity, nil, id]
          layer_rows = composition_rows(group, kind, level, id)
          openings = params.fetch('openings', []).map do |item|
            label = Openings::TYPES.fetch(item['kind'])
            mark = item['mark'].to_s.empty? ? label : item['mark']
            spec = [group.name, item.dig('sash', 'product_id')].compact.join(' / ')
            [level, label, mark, spec, item['width'], item['height'], item['sill'], nil, id, "#{id}/#{item.fetch('id')}"]
          end
          [{ values: base, target: id }, *(layer_rows + openings).map { |row| { values: row, target: id } }]
        end.sort_by { |row| row[:values].first(3) }
      end

      def volume(group, kind)
        value = group.manifold? ? group.volume : (%w[wall slab].include?(kind) ? solid_volume(group) : nil)
        (value * 0.0254**3).round(5) if value
      end

      def determinant(transform)
        origin = ORIGIN.transform(transform)
        x, y, z = [[1, 0, 0], [0, 1, 0], [0, 0, 1]].map { |p| Geom::Point3d.new(p).transform(transform) - origin }
        x.cross(y).dot(z).abs
      end

      def solid_volume(group)
        return group.volume if group.manifold?
        return unless group.entities.grep(Sketchup::Face).empty?

        volumes = group.entities.grep(Sketchup::Group).map { |child| solid_volume(child) }
        return if volumes.empty? || volumes.any?(&:nil?)

        volumes.sum * determinant(group.transformation)
      end

      def composition_rows(group, kind, level, id)
        return [] unless %w[wall slab].include?(kind)

        layers = {}
        Composition.each_layer(group) do |part, layer, index, transform|
          item = layers[index] ||= [layer, []]
          parent = transform * part.transformation.inverse
          item.last << (part.volume * determinant(parent) if part.manifold?)
        end
        layers.sort_by(&:first).map do |index, (layer, volumes)|
          quantity = (volumes.sum * 0.0254**3).round(5) unless volumes.any?(&:nil?)
          [level, "#{API.object_name(kind)}・層", layer.fetch('name'), group.name, layer.fetch('thickness'),
           nil, nil, quantity, id, "#{id}/layer/#{index + 1}"]
        end
      end

      def show
        if @dialog&.visible?
          @dialog.bring_to_front
          refresh
          return
        end

        @dialog = UI::HtmlDialog.new(dialog_title: 'SketchBRep 階別一覧',
                                     preferences_key: 'Higeotoko.SbrArchitecture.Schedule',
                                     width: 850, height: 485, min_width: 480, resizable: true,
                                     style: UI::HtmlDialog::STYLE_DIALOG)
        @dialog.set_file(File.join(__dir__, 'schedule.html'))
        @dialog.add_action_callback('refresh') { API.report_errors { refresh } }
        @dialog.add_action_callback('select') { |_context, token, id| API.report_errors { select_group(token, id) } }
        @dialog.add_action_callback('csv') { |_context, token, level, kind| API.report_errors { export_csv(token, level, kind) } }
        @dialog.set_on_closed { @dialog = nil }
        @dialog.show
      end

      def refresh
        model = Sketchup.active_model
        @dialog&.execute_script("receiveSchedule(#{JSON.generate({ token: model.object_id.to_s, headers: HEADERS, rows: rows(model) })})")
      end

      def active_model(token)
        model = Sketchup.active_model
        raise ArgumentError, 'モデルが変わりました。一覧を更新してください。' if token != model.object_id.to_s

        model
      end

      def select_group(token, id)
        model = active_model(token)
        API.top_level!(model)
        group = model.find_entity_by_persistent_id(Integer(id, 10))
        raise ArgumentError, '対象が見つかりません。一覧を更新してください。' unless group.is_a?(Sketchup::Group)
        raise ArgumentError, '対象が非表示です。表示してから選択してください。' if group.hidden? || !group.layer.visible?

        model.selection.clear
        model.selection.add(group)
        model.active_view.zoom(group)
      end

      def export_csv(token, level, kind)
        model = active_model(token)
        file = UI.savepanel('階別一覧をCSVに保存', '', 'SketchBRep-階別一覧.csv')
        return unless file

        File.write(file, csv_for(model, level, kind), encoding: 'UTF-8')
      end

      def csv_for(model, level, kind)
        content = CSV.generate do |csv|
          csv << HEADERS
          rows(model).each do |row|
          values = row.fetch(:values)
            next unless (level.empty? || level == values[0]) && (kind.empty? || kind == values[1])

            csv << values.map { |value| value.is_a?(String) && value.match?(/\A\s*[=+\-@]/) ? "'#{value}" : value }
          end
        end
        "\uFEFF#{content}"
      end
    end
  end
end
