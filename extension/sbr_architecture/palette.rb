# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class Palette
      API = SbrArchitecture
      TOOLS = {
        'wall' => ['壁', '芯を連続クリックし、Enterで確定。'],
        'slab' => ['床スラブ', '外周を3点以上クリックし、Enterで閉じる。'],
        'roof' => ['屋根', '外壁矩形の対角を2点クリック。切妻の棟は勾配方向と直交します。'],
        'slab_opening' => ['床開口', '上階の床スラブを選んで対角をクリック。'],
        'stair' => ['直階段', '上階の床スラブを選び、開口・下階・上る方向を指定。'],
        'room' => ['室', '閉じた壁の内側をクリックして室名と面積を登録。'],
        'column' => ['柱', '柱芯を1クリック。続けて配置できます。'],
        'beam' => ['梁', '梁芯の両端をクリック。作図高さに天端が揃います。'],
        'window' => ['窓開口', '形式・取付位置・配置基準を選び、壁をクリック。形式に応じて可動側を指定。'],
        'door' => ['扉開口', '形式と配置基準を選び、壁をクリック。形式に応じて引く方向や開く側を指定。'],
        'grid' => ['通り芯', '最初の交点を1クリック。線・符号・寸法をまとめて生成。'],
        'strip_foundation' => ['布基礎', '基礎芯を連続クリック。Enterで確定、始点をクリックすると一周を閉じます。'],
        'pad_foundation' => ['独立基礎', '中心を1クリック。矩形の底盤を作図高さの下に生成。']
      }.freeze

      def self.instance
        @instance ||= new
      end

      def self.show(edit_selected: false)
        instance.show(edit_selected)
      end

      def show(edit_selected)
        @edit_on_ready = edit_selected
        if @dialog&.visible?
          @dialog.bring_to_front
          edit_selection if edit_selected
          return
        end

        @dialog = UI::HtmlDialog.new(dialog_title: 'SketchUPbuildingTool 建築パレット',
                                     preferences_key: 'Higeotoko.SbrArchitecture.Palette',
                                     width: 445, height: 735, min_width: 345, min_height: 450,
                                     resizable: true, style: UI::HtmlDialog::STYLE_UTILITY)
        @dialog.set_file(File.join(__dir__, 'palette.html'))
        @dialog.add_action_callback('ready') { handle { refresh(true); show_tool; edit_selection if @edit_on_ready } }
        @dialog.add_action_callback('activateTool') do |_context, token, kind|
          handle { activate(kind) if current_model?(token) }
        end
        @dialog.add_action_callback('showTool') { handle { show_tool } }
        @dialog.add_action_callback('toolDefaults') { |_context, data| handle { update_defaults(JSON.parse(data)) } }
        @dialog.add_action_callback('drawContext') do |_context, data|
          handle do
            values = JSON.parse(data)
            if current_model?(values['token'])
              set_context(level: values['level'], z: values['z'], system: values['system'])
            end
          end
        end
        @dialog.add_action_callback('editSelection') { handle { edit_selection } }
        @dialog.add_action_callback('editPlanOpening') { |_context, data| handle { edit_plan_opening(JSON.parse(data)) } }
        @dialog.add_action_callback('toggleWorkBackground') { handle { WorkView.toggle(model); refresh } }
        @dialog.add_action_callback('repairGrid') do
          handle do
            count = GridStyle.repair(model)
            send_ui('message', { text: "通り芯#{count}件と現在の表示を整えました。", error: false })
          end
        end
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
        item if (TOOLS.key?(kind) && !%w[stair room].include?(kind)) || kind == 'sill'
      end

      def refresh(force = false)
        level_list = API.levels(model)
        level = API.active_level(model)
        z = API.draw_elevation(model)
        dark = WorkView.enabled?(model)
        key = [model.object_id, level_list, level, z, dark, API.structural_system(model)]
        if force || @model_key != key
          model_changed = @model_key && @model_key.first != key.first
          system_changed = @model_key && @model_key.last != key.last
          @editing = nil if model_changed
          @model_key = key
          send_ui('project', { token: key.first.to_s, levels: level_list.to_a, level: level&.first, z: z,
                               system: key.last, tools: TOOLS, systems: Catalog::SYSTEMS, dark: dark })
          show_tool if model_changed || (system_changed && !@editing)
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
                   followLabel: %w[slab roof].include?(kind) ? '階に関連付け' : '関連付け',
                   wallHead: wall_head }
               end
        send_ui('selection', info)
      end

      def follow_selection
        item = selection
        raise ArgumentError, '関連付ける柱・梁・壁・床・屋根を1つ選択してください。' unless item && Follow::KINDS.include?(Follow.kind(item))

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
                   height_label = case params.dig('head', 'mode')
                                  when 'roof' then '壁上端の最高高さ (mm)'
                                  when nil then '壁高さ (mm)'
                                  else '参照面までの高さ (mm)'
                                  end
                   thickness = params.fetch('thickness', 120)
                   [field('thickness', '壁厚 (mm)', thickness),
                    field('height', height_label, params.fetch('height', 2700))
                      .merge(readOnly: !!params['head']),
                    field('alignment', '基準線からの配置', params.fetch('alignment', '中央'), 'select',
                          Layout::ALIGNMENTS.map { |name| [name, name] }),
                    field('outside_side', '外側の向き', params.fetch('outside_side', 'auto'), 'select', Layout::OUTSIDE_SIDES.to_a),
                    field('outer_offset', '芯から外面 (mm)', params.fetch('outer_offset', thickness / 2.0)).merge(signed: true),
                    field('inner_offset', '芯から内面 (mm)', params.fetch('inner_offset', thickness / 2.0)).merge(signed: true)]
                 when 'slab'
                   [field('thickness', '床厚 (mm)', params.fetch('thickness', 150))]
                 when 'roof'
                   roof = Roof::DEFAULTS.merge(params)
                   [field('roof_type', '屋根の形式', roof['roof_type'], 'select', Roof::TYPES.to_a),
                    field('rise_direction', '勾配方向', roof['rise_direction'], 'select', Roof::DIRECTIONS.to_a),
                    field('pitch', '勾配 (寸)', roof['pitch']).merge(minimum: 0.1),
                    field('overhang', '軒の出 (mm)', roof['overhang']).merge(minimum: 0),
                    field('eave_offset', '作図高さから低い軒の上端まで (mm)', roof['eave_offset']).merge(signed: true),
                    field('thickness', '屋根厚・鉛直 (mm)', roof['thickness'])]
                 when 'window', 'door'
                   width, height, sill = Openings.fields(kind)
                   items = [field('width', '開口幅 (mm)', params.fetch('width', width)),
                            field('height', '開口高さ (mm)', params.fetch('height', height))]
                   if kind == 'window'
                     items.unshift(field('window_type', '窓の形式', Openings.window_type(params), 'select', Openings::WINDOW_TYPES.to_a))
                     items << field('sill', '腰高 (mm)', params.fetch('sill', sill)).merge(minimum: 0)
                     items.concat(window_mount_fields(Openings.window_mount(params)))
                   else
                     items.unshift(*door_fields(params))
                   end
                   items << field('anchor', '配置基準点', params.fetch('anchor', 'center'), 'select', Openings::ANCHORS.to_a)
                   items << field('mark', '建具記号（任意）', params.fetch('mark', ''), 'text').merge(optional: true)
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

      def window_mount_fields(mount)
        [field('mount_mode', '取付位置', mount.fetch('mode'), 'select', Openings::WINDOW_MOUNTS.to_a),
         field('exterior_side', '外側', mount.fetch('side'), 'select', Openings::EXTERIOR_SIDES.to_a),
         field('mount_offset', '外壁面からの距離 (mm)', mount.fetch('offset').positive? ? mount.fetch('offset') : 30)]
      end

      def door_fields(params)
        [field('door_type', '扉の形式', Doors.type(params), 'select', Doors::TYPES.to_a),
         field('inactive_width', '子扉幅 (mm)', params.fetch('inactive_width', 300))]
      end

      def door_directions
        Doors::TYPES.keys.to_h do |type|
          [type, { key: Doors.direction_key('door_type' => type), options: Doors.direction_options(type).to_a }]
        end
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
                    outer, inner = values.values_at('outer_offset', 'inner_offset')
                    if values['alignment'] == Layout::ECCENTRIC && layers&.any?
                      inner = values.fetch('thickness') - Layout.mm(outer, '芯から外面')
                    end
                    Layout.wall_parameters(*values.values_at('thickness', 'height', 'alignment'), outer: outer, inner: inner,
                                           outside_side: values.fetch('outside_side', 'auto'))
                  when 'slab'
                    { 'thickness' => Layout.mm(values['thickness'], '床厚', positive: true) }
                  when 'roof'
                    Roof.parameters(values)
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
        if kind == 'wall' && params['alignment'] != Layout::ECCENTRIC
          %w[outer_offset inner_offset outside_side].each { |key| params.delete(key) }
        end
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

      def current_model?(token)
        return true if token == model.object_id.to_s

        refresh(true)
        false
      end

      def saved_defaults(current, kind, system)
        return unless @defaults_model == current

        @defaults[[kind, (system if API::FRAMING.include?(kind))]]
      end

      def store_defaults(current, kind, system, params)
        if @defaults_model != current
          @defaults_model = current
          @defaults = {}
        end
        @defaults[[kind, (system if API::FRAMING.include?(kind))]] = params
      end

      def show_tool
        return unless @dialog

        @editing = nil
        kind = @tool_model == model ? @kind : 'wall'
        system = API.structural_system(model)
        send_ui('tool', schema(kind, system, saved_defaults(model, kind, system)))
      end

      def update_defaults(data)
        return unless current_model?(data['token'])

        kind = data.fetch('kind')
        TOOLS.fetch(kind)
        system = data.fetch('system')
        Catalog::SYSTEMS.fetch(system)
        values = data.fetch('values')
        params = if Openings::TYPES.key?(kind)
                   Openings.parameters(kind, values)
                 else
                   params_from(kind, system, values, layer_rows: data['layers'])
                 end
        store_defaults(model, kind, system, params)
        if @kind == kind && API.structural_system(model) == system
          update_placement
        end
        send_ui('message', { text: '', error: false })
      end

      def placement_values(current, kind)
        system = API.structural_system(current)
        level = API.active_level(current)
        z = API.draw_elevation(current)
        params = saved_defaults(current, kind, system)
        if Openings::TYPES.key?(kind)
          width, height, sill = Openings.fields(kind)
          defaults = { 'width' => width, 'height' => height, 'sill' => sill }
          defaults['door_type'] = 'single' if kind == 'door'
          params ||= Openings.parameters(kind, defaults)
          return [params, Openings::PlanPick.for(current, level&.first, z)]
        end
        params ||= case kind
                   when 'wall' then Layout.wall_parameters(*API::WALL_DEFAULTS.values_at(0, 1, 3))
                   when 'grid' then API.grid_params(*API::GRID_DEFAULTS.first(4))
                   when 'slab' then { 'thickness' => 150.0 }
                   when 'roof' then Roof::DEFAULTS
                   else API.initial_member(kind, API::FRAMING.include?(kind) ? system : 'rc')
                   end
        [API.attach_level(params.dup, level, z), z]
      end

      def activate(kind)
        current = model
        API.top_level!(current)
        TOOLS.fetch(kind)
        if kind == 'slab_opening'
          slab = SlabOpenings.selected(current)
          SlabOpenings.validate_host!(slab)
          current.select_tool(API::Placement.new(current, kind, { 'host_id' => slab.persistent_id }, slab.transformation.origin.z.to_mm))
          return
        end
        return Stairs.dialog(current) if kind == 'stair'
        if kind == 'room'
          plan = Openings::PlanPick.active_spec(current)
          level = plan ? plan.fetch('level') : API.active_level(current)&.first
          raise ArgumentError, '室を登録する階の平面を開くか、作図レベルを選んでください。' unless level

          current.select_tool(API::Placement.new(current, kind, { 'level' => level }, API.levels(current).fetch(level)))
          return
        end

        params, datum = placement_values(current, kind)
        tool = if Openings::TYPES.key?(kind)
                 Openings::Placement.new(current, params, plan: datum)
               else
                 API::Placement.new(current, kind, params, datum)
               end
        current.select_tool(tool)
        @tool_model, @kind, @placement = current, kind, tool
        refresh if @dialog
        show_tool
      end

      def update_placement
        return unless @tool_model == model && @placement&.active?

        @placement.update_settings(*placement_values(model, @kind))
      end

      def set_context(level: nil, z: nil, system: nil)
        current = model
        API.top_level!(current)
        changes = {}
        if level
          level = API.levels(current).key?(level) ? level : ''
          changes['active_level'] = level if level != API.active_level(current)&.first.to_s
          if level.empty? && !z.nil?
            elevation = Layout.mm(z, '作図高さ')
            changes['manual_z'] = elevation if elevation != current.get_attribute(API::DICT, 'manual_z', 0)
          end
        end
        if system && system != API.structural_system(current)
          Catalog::SYSTEMS.fetch(system)
          changes['structural_system'] = system
        end
        return if changes.empty?

        API.operation(current, '作図条件を変更') do
          changes.each { |key, value| current.set_attribute(API::DICT, key, value) }
        end
        update_placement
        refresh if @dialog
      end

      def edit_plan_opening(data)
        current = model
        API.top_level!(current)
        return refresh(true) if data['token'] != current.object_id.to_s

        picker = Openings::PlanPick.for(current, data['level'], data['z'])
        raise ArgumentError, '階別平面シーンまたは平行投影の上面表示を開いてください。' unless picker

        current.select_tool(Openings::PlanEdit.new(current, picker) do |wall, opening_id|
          handle do
            raise ArgumentError, 'モデルが切り替わりました。' unless model == current

            current.selection.clear
            current.selection.add(wall)
            edit_selection(focus_opening: opening_id)
          end
        end)
        send_ui('message', { text: '平面上で編集する窓・扉の開口をクリックしてください。', error: false })
      end

      def edit_selection(focus_opening: nil)
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
          data = opening.merge('label' => Openings::TYPES.fetch(opening['kind']))
          if opening['kind'] == 'window'
            data['fields'] = [
              field('window_type', '窓の形式', Openings.window_type(opening), 'select', Openings::WINDOW_TYPES.to_a),
              *window_mount_fields(Openings.window_mount(opening)),
              field('hinge', '吊り元・可動側', opening.fetch('hinge', 'start'), 'select',
                    [['start', '区間始点側'], ['end', '区間終点側']])
            ]
          else
            data['fields'] = door_fields(opening)
          end
          data
        end
        options = openings.any? { |opening| opening['kind'] == 'window' } ? Sashes.options : []
        send_ui('edit', data.merge(id: item.persistent_id.to_s, name: item.name, openings: openings,
                                   sashOptions: options, doorDirections: door_directions, focusOpening: focus_opening))
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

            if opening['kind'] == 'door' && !opening.key?('door_type') &&
               values['door_type'] == 'single' && values['swing'] == opening.fetch('swing', 'none')
              values = values.reject { |key, _| key == 'door_type' }
            end
            changed = opening.merge(Openings.parameters(opening.fetch('kind'), values),
                                    'offset' => Layout.mm(values['offset'], '区間始点からの距離', positive: true))
            if values.key?('product') && opening['kind'] == 'window'
              changed['sash'] = Sashes.config(values, opening['sash'])
              changed.delete('sash') unless changed['sash']
            end
            if opening['kind'] == 'window'
              changed.delete('swing')
              changed.delete('hinge') unless Openings::HANDED_WINDOWS.include?(changed['window_type'])
            else
              %w[swing motion].each { |key| changed.delete(key) unless key == Doors.direction_key(changed) }
              changed.delete('inactive_width') unless Doors.type(changed) == 'unequal'
            end
            changed
          end
          Openings.validate(params, API.wall_profiles(params))
        end
        placement = grid_placement(item, data.fetch('values')) if kind == 'grid'
        if params != previous || placement
          API.regenerate(item, params, placement: placement, refresh_plan: kind == 'wall')
        end
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
