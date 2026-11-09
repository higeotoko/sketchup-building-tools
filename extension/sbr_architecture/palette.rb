# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class Palette
      API = SbrArchitecture
      TOOLS = {
        'wall' => ['壁', '芯を連続クリックし、Enterで確定。'],
        'slab' => ['床スラブ', '外周を3点以上クリックし、Enterで閉じる。'],
        'column' => ['柱', '柱芯を1クリック。続けて配置できます。'],
        'beam' => ['梁', '梁芯の両端をクリック。作図高さに天端が揃います。'],
        'window' => ['窓開口', '開口を入れる壁面にカーソルを置き、横方向の中心をクリック。'],
        'door' => ['扉開口', '開口を入れる壁面にカーソルを置き、横方向の中心をクリック。'],
        'grid' => ['通り芯', '最初の交点を1クリック。線・符号・寸法をまとめて生成。'],
        'strip_foundation' => ['布基礎', '基礎芯の両端をクリック。立上りと底盤を一体で生成。'],
        'pad_foundation' => ['独立基礎', '中心を1クリック。矩形の底盤を作図高さの下に生成。']
      }.freeze

      def self.show(edit_selected: false)
        @instance ||= new
        @instance.show(edit_selected)
      end

      def show(edit_selected)
        @edit_on_ready = edit_selected
        if @dialog&.visible?
          @dialog.bring_to_front
          edit_selection if edit_selected
          return
        end

        @dialog = UI::HtmlDialog.new(dialog_title: 'SketchBRep 建築パレット',
                                     preferences_key: 'Higeotoko.SbrArchitecture.Palette',
                                     width: 445, height: 735, min_width: 345, min_height: 450,
                                     resizable: true, style: UI::HtmlDialog::STYLE_UTILITY)
        @dialog.set_file(File.join(__dir__, 'palette.html'))
        @dialog.add_action_callback('ready') { handle { refresh(true); edit_selection if @edit_on_ready } }
        @dialog.add_action_callback('schema') do |_context, request, kind, system|
          handle { send_ui('schema', [request, schema(kind, system)]) }
        end
        @dialog.add_action_callback('place') { |_context, data| handle { place(JSON.parse(data)) } }
        @dialog.add_action_callback('editSelection') { handle { edit_selection } }
        @dialog.add_action_callback('applyEdit') { |_context, data| handle { apply_edit(JSON.parse(data)) } }
        @dialog.add_action_callback('schedule') { handle { Schedule.show } }
        @dialog.add_action_callback('drawings') { handle { Drawings.show } }
        @dialog.add_action_callback('editLevels') { handle { API.edit_levels; refresh } }
        @dialog.add_action_callback('followSelection') { handle { follow_selection } }
        @dialog.add_action_callback('wallHead') { handle { wall_head } }
        @dialog.set_on_closed do
          UI.stop_timer(@timer) if @timer
          @dialog = @timer = @model_key = @selection_key = @editing = nil
        end
        @dialog.show
        @timer = UI.start_timer(0.4, true) { refresh if @model_key && @dialog&.visible? }
      end

      def send_ui(method, value)
        @dialog&.execute_script("PaletteUI.#{method}(#{JSON.generate(value)})")
      end

      def handle
        yield
      rescue ArgumentError, KeyError, Catalog::STEEL::Error => e
        send_ui('message', { text: e.message, error: true })
      rescue StandardError => e
        warn(e.full_message)
        send_ui('message', { text: "処理できませんでした。#{e.message}", error: true })
      end

      def model
        Sketchup.active_model
      end

      def selection
        return if model.active_path || model.selection.length != 1

        item = model.selection.first
        return unless item.is_a?(Sketchup::Group) && item.valid?

        kind = item.get_attribute(API::DICT, 'kind')
        item if TOOLS.key?(kind) || kind == 'sill'
      end

      def refresh(force = false)
        level_list = API.levels(model)
        level = API.active_level(model)
        key = [model.object_id, level_list, level, API.structural_system(model)]
        if force || @model_key != key
          @editing = nil if @model_key&.first != key.first
          @model_key = key
          send_ui('project', { token: key.first.to_s, levels: level_list.to_a, level: level&.first,
                               system: key.last, tools: TOOLS, systems: Catalog::SYSTEMS })
        end
        item = selection
        raw = item&.get_attribute(API::DICT, 'parameters')
        links = item && Follow.data(item)
        key = item && [model.object_id, item.persistent_id, item.name, item.locked?, raw, links]
        return if !force && key == @selection_key

        @selection_key = key
        @editing = nil unless item && @editing == edit_key(item, raw)
        info = if item
                 kind = Follow.kind(item)
                 wall_head = WallHeads::MODES.fetch(JSON.parse(raw).dig('head', 'mode') || 'fixed') if kind == 'wall'
                 { id: item.persistent_id.to_s, name: item.name, locked: item.locked?,
                   canFollow: Follow::KINDS.include?(kind), linked: !links.empty?,
                   followLabel: kind == 'slab' ? '階に関連付け' : '関連付け',
                   wallHead: wall_head }
               end
        send_ui('selection', info)
      end

      def follow_selection
        item = selection
        raise ArgumentError, '関連付ける柱・梁・壁・床を1つ選択してください。' unless item && Follow::KINDS.include?(Follow.kind(item))

        Follow.dialog(item)
        refresh
      end

      def wall_head
        item = selection
        raise ArgumentError, '壁を1つ選択してください。' unless item && Follow.kind(item) == 'wall'

        raw = item.get_attribute(API::DICT, 'parameters')
        editing = @editing == edit_key(item, raw)
        WallHeads.pick(item)
        return if raw == item.get_attribute(API::DICT, 'parameters')

        refresh
        edit_selection if editing
        send_ui('message', { text: '壁上端の納まりを反映しました。', error: false })
      end

      def field(key, label, value, type = 'number', options = nil)
        { key: key, label: label, value: value, type: type, options: options }
      end

      def schema(kind, system, previous = nil)
        params = previous || {}
        fields = case kind
                 when 'wall'
                   [field('thickness', '壁厚 (mm)', params.fetch('thickness', 120)),
                    field('height', params['head'] ? '参照面までの高さ (mm)' : '壁高さ (mm)', params.fetch('height', 2700))
                      .merge(readOnly: !!params['head']),
                    field('alignment', '壁芯からの寄せ', params.fetch('alignment', '中央'), 'select',
                          Layout::ALIGNMENTS.map { |name| [name, name] })]
                 when 'slab'
                   [field('thickness', '床厚 (mm)', params.fetch('thickness', 150))]
                 when 'window', 'door'
                   width, height, sill = Openings.fields(kind)
                   items = [field('width', '開口幅 (mm)', width), field('height', '開口高さ (mm)', height)]
                   items << field('sill', '腰高 (mm)', sill).merge(minimum: 0) if kind == 'window'
                   items << field('mark', '建具記号（任意）', '', 'text').merge(optional: true)
                   items
                 when 'grid'
                   %w[x y].flat_map do |axis|
                     intervals = params.fetch("#{axis}_spans", axis == 'x' ? '910*4' : '910*3')
                     [field("#{axis}_spans", "#{axis.upcase}方向の間隔 (mm)", Array(intervals).join(','), 'text'),
                      field("#{axis}_names", "#{axis.upcase}方向の符号", params.fetch("#{axis}_label_spec", axis.upcase), 'text')]
                   end
                 else
                   if API::FRAMING.include?(kind) && Catalog::SYSTEMS.key?(system)
                     framing_schema(kind, system, params)
                   else
                     prompts, keys = API.member_fields(kind)
                     defaults = previous || API.initial_member(kind, 'rc')
                     keys.zip(prompts).map { |key, label| field(key, label, defaults.fetch(key)) }
                   end
                 end
        data = { kind: kind, system: system, title: TOOLS.fetch(kind, ['土台']).first, fields: fields,
                 tip: TOOLS.fetch(kind, ['土台', '保存済みの土台寸法を編集。']).last }
        if %w[wall slab].include?(kind)
          data[:layers] = params.fetch('layers', [])
          data[:patterns] = Composition::PATTERNS.to_a
        end
        data
      end

      def framing_schema(kind, system, previous)
        defaults = previous.empty? ? API.initial_member(kind, system) : previous
        if system == 'rc'
          prompts, keys = API.member_fields(kind)
          return keys.zip(prompts).map { |key, label| field(key, label, defaults.fetch(key)) }
        end

        fields = if system == 'timber'
                   roles = Catalog.timber_roles(kind).map do |id, role|
                     sections = Catalog.timber_sections(role).map { |section_id, section| [section_id, section.fetch('name')] }
                     [id, role.fetch('name'), role.fetch('default_section'), sections]
                   end
                   [field('section_id', '木造の役割と断面', defaults.fetch('section_id'), 'timber', roles)
                    .merge(role: defaults.fetch('role'))]
                 else
                   [field('section_id', '鋼材断面', defaults.fetch('section_id'), 'steel', Catalog.steel_options)]
                 end
        fields << field('height', '柱高さ (mm)', defaults.fetch('height')) if kind == 'column'
        fields
      end

      def params_from(kind, system, values, previous = {}, layer_rows: nil)
        layers = if %w[wall slab].include?(kind)
                   layer_rows.nil? ? previous.fetch('layers', []) : Composition.parse(layer_rows)
                 end
        if layers&.any?
          values = values.merge('thickness' => layers.sum { |layer| layer.fetch('thickness') })
        end
        changed = case kind
                  when 'wall'
                    API.wall_params(*values.values_at('thickness', 'height', 'alignment'))
                  when 'slab'
                    { 'thickness' => Layout.mm(values['thickness'], '床厚', positive: true) }
                  when 'grid'
                    API.grid_params(*values.values_at('x_spans', 'y_spans', 'x_names', 'y_names'))
                  else
                    if API::FRAMING.include?(kind) && system == 'timber'
                      Catalog.timber_params(kind, *values.values_at('role', 'section_id', 'height'))
                    elsif API::FRAMING.include?(kind) && system == 'steel'
                      Catalog.steel_params(Catalog.steel.fetch(values['section_id']), kind, values['height'])
                    else
                      prompts, keys = API.member_fields(kind)
                      API.member_params(prompts, keys, values.values_at(*keys))
                    end
                  end
        params = previous.merge(changed)
        if layers&.any?
          params['layers'] = layers
        elsif layers
          params.delete('layers')
        end
        params['system'] = system if Catalog::SYSTEMS.key?(system) && API::FRAMING.include?(kind)
        params['system'] = 'rc' if %w[strip_foundation pad_foundation].include?(kind)
        API.foundation_section(params) if kind == 'strip_foundation'
        params
      end

      def place(data)
        API.top_level!(model)
        raise ArgumentError, 'モデルが切り替わりました。もう一度ツールを選んでください。' if data['token'] != model.object_id.to_s

        kind = data.fetch('kind')
        system = data.fetch('system')
        TOOLS.fetch(kind)
        Catalog::SYSTEMS.fetch(system)
        if Openings::TYPES.key?(kind)
          params = Openings.parameters(kind, data.fetch('values'))
          model.select_tool(Openings::Placement.new(model, params))
          send_ui('message', { text: TOOLS.fetch(kind).last, error: false })
          return
        end
        z = Layout.mm(data['z'], '作図高さ')
        level = data['level']
        params = params_from(kind, system, data.fetch('values'), layer_rows: data['layers'])
        params['level'] = level if API.levels(model)[level] == z
        model.select_tool(API::Placement.new(model, kind, params, z))
        send_ui('message', { text: TOOLS.fetch(kind).last, error: false })
      end

      def edit_selection
        item = selection
        raise ArgumentError, '建築ツールで作った要素を1つ選択してください。' unless item
        raise ArgumentError, 'ロックを解除してから編集してください。' if item.locked?

        kind = item.get_attribute(API::DICT, 'kind')
        raw = item.get_attribute(API::DICT, 'parameters')
        params = JSON.parse(raw)
        data = schema(kind, params['system'], params)
        @editing = edit_key(item, raw)
        if kind == 'grid'
          %w[x y z].zip(item.transformation.origin.to_a.map(&:to_mm)).each do |axis, coordinate|
            data[:fields] << field("origin_#{axis}", "原点 #{axis.upcase} (mm)", coordinate.round(6)).merge(signed: true)
          end
        end
        openings = params.fetch('openings', []).map do |opening|
          opening.merge('label' => Openings::TYPES.fetch(opening['kind']))
        end
        options = openings.any? { |opening| opening['kind'] == 'window' } ? Sashes.options : []
        send_ui('edit', data.merge(id: item.persistent_id.to_s, name: item.name, openings: openings, sashOptions: options))
      end

      def apply_edit(data)
        API.top_level!(model)
        item = selection
        raw = item&.get_attribute(API::DICT, 'parameters')
        unless item && !item.locked? && @editing == edit_key(item, raw) && data['id'] == item.persistent_id.to_s
          raise ArgumentError, '選択または要素が変わりました。選び直してから編集してください。'
        end

        previous = JSON.parse(raw)
        kind = item.get_attribute(API::DICT, 'kind')
        params = params_from(kind, previous['system'], data.fetch('values'), previous, layer_rows: data['layers'])
        if kind == 'wall' && data.key?('openings')
          prior = previous.fetch('openings', []).to_h { |opening| [opening.fetch('id'), opening] }
          params['openings'] = data.fetch('openings').map do |values|
            opening = prior.delete(values.fetch('id'))
            raise ArgumentError, '開口を読み直してください。' unless opening

            changed = opening.merge(Openings.parameters(opening.fetch('kind'), values),
                                    'offset' => Layout.mm(values['offset'], '区間始点からの距離', positive: true))
            if values.key?('product') && opening['kind'] == 'window'
              changed['sash'] = Sashes.config(values, opening['sash'])
              changed.delete('sash') unless changed['sash']
            end
            changed
          end
          Openings.validate(params, API.wall_profiles(params))
        end
        placement = grid_placement(item, data.fetch('values')) if kind == 'grid'
        API.regenerate(item, params, placement: placement) if params != previous || placement
        @editing = edit_key(item, item.get_attribute(API::DICT, 'parameters'))
        send_ui('message', { text: '選択中の要素に反映しました。', error: false })
      end

      def edit_key(item, raw)
        transform = item.transformation.to_a if Follow.kind(item) == 'grid'
        [item, raw, transform]
      end

      def grid_placement(item, values)
        return unless values.key?('origin_x')

        coordinates = %w[x y z].map { |axis| Layout.mm(values["origin_#{axis}"], "原点 #{axis.upcase}") }
        offset = API.point(*coordinates) - item.transformation.origin
        return if offset.length.to_mm < 0.000001

        Geom::Transformation.translation(offset) * item.transformation
      end
    end
  end
end
