# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require_relative 'layout'
require_relative 'catalog'
require_relative 'openings'
require_relative 'composition'
require_relative 'sashes'
require_relative 'follow'
require_relative 'wall_heads'
require_relative 'column_centers'
require_relative 'schedule'
require_relative 'plan_linework'
require_relative 'layer_hatches'
require_relative 'drawings'
require_relative 'layout_sheets'
require_relative 'ifc_export'
require_relative 'palette'

module Higeotoko
  module SbrArchitecture
    DICT = 'higeotoko.sbr_architecture'
    MENU_TITLE = 'SketchBRep 建築ツール'
    WALL_DEFAULTS = [120, 2700, 0, '中央'].freeze
    GRID_DEFAULTS = ['910*4', '910*3', 'X', 'Y', 0].freeze
    MEMBERS = {
      'column' => ['柱', 105, 105, 2700],
      'beam' => ['梁', 105, 240],
      'sill' => ['土台', 105, 105],
      'strip_foundation' => ['布基礎', 150, 400, 450, 150],
      'pad_foundation' => ['独立基礎', 900, 900, 250]
    }.freeze
    RC_SIZES = { 'column' => [400, 400, 2700], 'beam' => [300, 500] }.freeze
    FRAMING = %w[column beam].freeze
    DEFAULT_LEVELS = 'GL=0,1FL=450,2FL=3200'.freeze
    module_function

    def point(x, y, z = 0)
      Geom::Point3d.new(x.mm, y.mm, z.mm)
    end

    def wall_params(thickness, height, alignment)
      {
        'thickness' => Layout.mm(thickness, '壁厚', positive: true),
        'height' => Layout.mm(height, '壁高さ', positive: true),
        'alignment' => alignment
      }
    end

    def grid_params(x_spans, y_spans, x_names, y_names)
      x = Layout.spans(x_spans)
      y = Layout.spans(y_spans)
      {
        'x_spans' => x,
        'y_spans' => y,
        'x_names' => Layout.labels(x_names, x.size + 1),
        'y_names' => Layout.labels(y_names, y.size + 1),
        'x_label_spec' => Layout.normalize(x_names),
        'y_label_spec' => Layout.normalize(y_names)
      }
    end

    def write_prism(group, profile, base, height)
      face = group.entities.add_face(profile.map { |x, y| point(x, y, base) })
      raise ArgumentError, '底面を作成できませんでした。' unless face

      face.reverse! if face.normal.z.negative?
      face.pushpull(height.mm)
      raise ArgumentError, '立体にできませんでした。' unless group.manifold?

      group.entities.each { |entity| entity.layer = group.model.layers[0] }
    end

    def write_wall(group, params, sashes)
      profiles = wall_profiles(params)
      openings = Openings.validate(params, profiles)
      layers = Composition.bands(params)
      nested = !profiles.one? || layers.any? || openings.values.flatten.any? { |opening| opening['sash'] }
      profiles.each_with_index do |profile, index|
        segment = group
        if nested
          segment = group.entities.add_group
          segment.name = "壁 #{index + 1}"
          segment.layer = group.model.layers[0]
        end
        if layers.any?
          layers.each do |layer, layer_index, from, to|
            layer_profile = Composition.wall_profile(profile, from, to, params.fetch('thickness'))
            target = Composition.layer_group(segment, layer, layer_index)
            layer_params = params.merge('height' => WallHeads.layer_height(params, layer_index))
            write_wall_segment(target, layer_params, layer_profile, index, openings)
          end
        else
          write_wall_segment(segment, params, profile, index, openings)
        end
      end
      Sashes.write(group, params, profiles, sashes)
    end

    def write_wall_segment(group, params, profile, index, openings)
      if openings.key?(index)
        Openings.write_segment(group, params, profile, index, openings.fetch(index))
      else
        write_prism(group, profile, 0, params.fetch('height'))
      end
    end

    def member_profile(kind, params)
      width = params.fetch('width')
      if point_member?(kind)
        x = width / 2
        y = params.fetch('depth') / 2
        [[-x, -y], [x, -y], [x, y], [-x, y]]
      else
        Layout.wall_profiles([[0.0, 0.0], params.fetch('end')], width, '中央').first
      end
    end

    def point_member?(kind)
      %w[column pad_foundation].include?(kind)
    end

    def steel_member(kind, params)
      section = Catalog.steel.fetch(params.fetch('section_id'))
      endpoint = kind == 'column' ? point(0, 0, params.fetch('height')) : point(*params.fetch('end'))
      reference = kind == 'column' ? 'center' : 'top'
      # Angle sections expose leg references. Their uppermost point is still
      # aligned to the beam datum through the generator's outer-top reference.
      reference = 'outer_top' if reference == 'top' && !section.placement_references.include?('top')
      Catalog::STEEL::Member.new(section, point(0, 0), endpoint, section.rotations.first, reference)
    end

    def steel_section_ends(member)
      transform = member.transformation
      member.section.geometry_loops_mm.map do |loop|
        [0, member.length.to_mm].map { |x| loop.map { |y, z| point(x, y, z).transform(transform) } }
      end
    end

    def foundation_section(params)
      width, rise, footing, thickness = params.values_at('width', 'rise', 'footing_width', 'footing_thickness')
      unless footing > width
        raise ArgumentError, '底盤の幅は立上り幅より大きくしてください。'
      end

      half_foot = footing / 2.0
      half_stem = width / 2.0
      bottom = -rise - thickness
      [[-half_foot, bottom], [half_foot, bottom], [half_foot, -rise], [half_stem, -rise],
       [half_stem, 0], [-half_stem, 0], [-half_stem, -rise], [-half_foot, -rise]]
    end

    def foundation_ends(params)
      x, y = params.fetch('end')
      length = Math.hypot(x, y)
      raise ArgumentError, '基礎の長さは1 mm以上にしてください。' if length < Layout::MIN_MM

      start = foundation_section(params).map { |u, z| point(-y * u / length, x * u / length, z) }
      direction = Geom::Vector3d.new(x.mm, y.mm, 0)
      [start, start.map { |p| p + direction }]
    end

    def write_strip(group, params)
      start, finish = foundation_ends(params)
      vector = finish.first - start.first
      face = group.entities.add_face(start)
      raise ArgumentError, '基礎断面を作成できませんでした。' unless face

      face.reverse! if face.normal.dot(vector).negative?
      face.pushpull(vector.length)
      raise ArgumentError, '基礎を立体にできませんでした。' unless group.manifold?
      group.entities.each { |entity| entity.layer = group.model.layers[0] }
    end

    def object_name(kind)
      return '壁' if kind == 'wall'
      return '通り芯' if kind == 'grid'
      return '床スラブ' if kind == 'slab'

      MEMBERS.fetch(kind).first
    end

    def generated_name(kind, params)
      system = Catalog::SYSTEMS[params['system']] if FRAMING.include?(kind)
      role = Catalog.timber_roles(kind).fetch(params['role']).fetch('name') if system == '木造' && params['role']
      [system, role || object_name(kind), params['section_id']].compact.join(' ')
    end

    def write_geometry(group, kind, params, sashes: {})
      if FRAMING.include?(kind) && params['system'] == 'steel'
        group.delete_attribute(Catalog::STEEL::DICTIONARY)
        Catalog::STEEL::Builder.populate(group, steel_member(kind, params))
        ColumnCenters.add(group, params) if kind == 'column'
        return
      end

      case kind
      when 'wall' then write_wall(group, params, sashes)
      when 'slab' then Composition.slab(group, params)
      when 'grid' then write_grid(group, params)
      when 'strip_foundation' then write_strip(group, params)
      else
        height = point_member?(kind) ? params.fetch('height') : params.fetch('depth')
        write_prism(group, member_profile(kind, params), kind == 'column' ? 0 : -height, height)
      end
      if kind == 'grid'
        group.entities.each { |entity| entity.layer = group.model.layers[0] }
      end
      ColumnCenters.add(group, params) if kind == 'column'
    end

    def write_grid(group, params)
      xs = Layout.stations(params.fetch('x_spans'))
      ys = Layout.stations(params.fetch('y_spans'))
      entities = group.entities
      extension = 360.0
      xs.zip(params.fetch('x_names')).each do |x, name|
        stations = [-extension] + ys + [ys.last + extension]
        stations.each_cons(2) { |a, b| entities.add_line(point(x, a), point(x, b)) }
        entities.add_text(name, point(x, -extension))
        entities.add_text(name, point(x, ys.last + extension))
      end
      ys.zip(params.fetch('y_names')).each do |y, name|
        stations = [-extension] + xs + [xs.last + extension]
        stations.each_cons(2) { |a, b| entities.add_line(point(a, y), point(b, y)) }
        entities.add_text(name, point(-extension, y))
        entities.add_text(name, point(xs.last + extension, y))
      end
      xs.each_cons(2) do |a, b|
        entities.add_dimension_linear(point(a, 0), point(b, 0), Geom::Vector3d.new(0, -720.mm, 0))
      end
      ys.each_cons(2) do |a, b|
        entities.add_dimension_linear(point(0, a), point(0, b), Geom::Vector3d.new(-720.mm, 0, 0))
      end
    end

    def operation(model, name)
      model.start_operation(name, true)
      begin
        result = yield
        model.commit_operation
        result
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    def wall_profiles(params)
      Layout.wall_profiles(params.fetch('points'), params.fetch('thickness'), params.fetch('alignment'))
    end

    def store_params(group, kind, params)
      group.set_attribute(DICT, 'kind', kind)
      group.set_attribute(DICT, 'parameters', JSON.generate(params))
      group.set_attribute(DICT, 'structural_system', params['system']) if params['system']
      group.set_attribute(DICT, 'role', params.fetch('role', kind))
    end

    def create(model, kind, params, origin)
      name = object_name(kind)
      group = operation(model, "#{name}を作成") do
        target = model.entities.add_group
        target.name = generated_name(kind, params)
        target.layer = model.layers[0]
        write_geometry(target, kind, params)
        target.transformation = Geom::Transformation.translation(origin) * target.transformation
        store_params(target, kind, params)
        target
      end
      model.selection.clear
      model.selection.add(group)
      group
    end

    def regenerate(group, params, placement: nil)
      kind = group.get_attribute(DICT, 'kind')
      name = object_name(kind)
      operation(group.model, "#{name}を編集") do
        previous = JSON.parse(group.get_attribute(DICT, 'parameters'))
        target = placement || placement_for(group, kind, previous)
        Follow.update_grid(group, previous, params, target) if kind == 'grid'
        params = WallHeads.resolve(group, params, target) if kind == 'wall'
        result = rebuild(group, kind, params, previous, target)
        WallHeads.refresh(group.model, changed: kind == 'grid' ? nil : group)
        result
      end
    end

    def placement_for(group, kind, params)
      tr = group.transformation
      FRAMING.include?(kind) && params['system'] == 'steel' ? tr * steel_member(kind, params).transformation.inverse : tr
    end

    def rebuild(group, kind, params, previous, placement = placement_for(group, kind, previous))
      replace_name = group.name == generated_name(kind, previous)
      group.make_unique
      sashes = kind == 'wall' ? Sashes.capture(group) : {}
      unless group.entities.clear!
        raise ArgumentError, 'グループ内部を再生成できませんでした。内部のロックを確認してください。'
      end
      group.transformation = IDENTITY
      write_geometry(group, kind, params, sashes: sashes)
      group.transformation = placement * group.transformation
      group.name = generated_name(kind, params) if replace_name
      store_params(group, kind, params)
    end

    def top_level!(model)
      raise ArgumentError, 'グループの編集を終了してから実行してください。' if model.active_path
    end

    def report_errors
      yield
    rescue ArgumentError, Catalog::STEEL::Error => e
      UI.messagebox(e.message)
    rescue StandardError => e
      warn(e.full_message)
      UI.messagebox("処理できませんでした。\n#{e.message}")
    end

    def start_wall(configure = false)
      report_errors do
        model = Sketchup.active_model
        top_level!(model)
        defaults = @wall_defaults || WALL_DEFAULTS
        level = active_level(model)
        values = [defaults[0], defaults[1], level&.last || defaults[2], defaults[3]]
        if configure
          values = UI.inputbox(['壁厚 (mm)', '高さ (mm)', '基準高さ Z (mm)', '壁芯からの寄せ'],
                               values, ['', '', '', Layout::ALIGNMENTS.join('|')], '壁の設定')
          next unless values
        end
        thickness, height, elevation, alignment = values
        z = Layout.mm(elevation, '基準高さ')
        params = attach_level(wall_params(thickness, height, alignment), level, z)
        @wall_defaults = values if configure
        model.select_tool(Placement.new(model, 'wall', params, z))
      end
    end

    def start_grid
      report_errors do
        model = Sketchup.active_model
        top_level!(model)
        level = active_level(model)
        defaults = (@grid_defaults || GRID_DEFAULTS).dup
        defaults[-1] = level.last if level
        values = UI.inputbox(['X方向の間隔 (mm)', 'Y方向の間隔 (mm)', 'Xの符号', 'Yの符号', '基準高さ Z (mm)'],
                             defaults, '通り芯を一括生成（例 910*4 または 910,1820）')
        next unless values

        z = Layout.mm(values.last, '基準高さ')
        params = attach_level(grid_params(*values.first(4)), level, z)
        @grid_defaults = values
        model.select_tool(Placement.new(model, 'grid', params, z))
      end
    end

    def member_fields(kind)
      case kind
      when 'column'
        [['幅 X (mm)', '奥行 Y (mm)', '柱高さ (mm)'], %w[width depth height]]
      when 'pad_foundation'
        [['底盤幅 X (mm)', '底盤幅 Y (mm)', '底盤厚 (mm)'], %w[width depth height]]
      when 'strip_foundation'
        [['立上り幅 (mm)', '立上り高さ (mm)', '底盤幅 (mm)', '底盤厚 (mm)'],
         %w[width rise footing_width footing_thickness]]
      else
        [['幅 (mm)', 'せい (mm)'], %w[width depth]]
      end
    end

    def member_params(prompts, keys, values)
      keys.zip(values.each_with_index.map { |value, i| Layout.mm(value, prompts[i], positive: true) }).to_h
    end

    def structural_system(model)
      model.get_attribute(DICT, 'structural_system', 'timber')
    end

    def change_system(system)
      report_errors do
        model = Sketchup.active_model
        top_level!(model)
        next if structural_system(model) == system

        model.select_tool(nil)
        operation(model, '作図の構造を切替') { model.set_attribute(DICT, 'structural_system', system) }
        Sketchup.set_status_text("#{Catalog::SYSTEMS.fetch(system)}で作図します。柱または梁のボタンを選択。", SB_PROMPT)
      end
    end

    def timber_settings(kind, params, elevation = nil)
      roles = Catalog.timber_roles(kind)
      role_id = params.fetch('role', roles.keys.first)
      names = roles.values.map { |role| role.fetch('name') }
      values = UI.inputbox(['部材の役割'], [roles.fetch(role_id).fetch('name')], [names.join('|')], '木造の部材を選択')
      return unless values

      role_id = roles.keys.fetch(names.index(values.first))
      role = roles.fetch(role_id)
      sections = Catalog.timber_sections(role)
      current = sections[params['section_id']] || sections.fetch(role.fetch('default_section'))
      prompts = ['断面 (mm)']
      defaults = [current.fetch('name')]
      lists = [sections.values.map { |s| s.fetch('name') }.join('|')]
      if kind == 'column'
        prompts << '柱高さ (mm)'
        defaults << params.fetch('height')
        lists << ''
      end
      if elevation
        prompts << elevation_label(kind)
        defaults << elevation
        lists << ''
      end
      values = UI.inputbox(prompts, defaults, lists, "木造 #{role.fetch('name')}")
      return unless values

      section_id = sections.find { |_id, section| section['name'] == values.first }.first
      [Catalog.timber_params(kind, role_id, section_id, values[1]), elevation ? values.last : nil]
    end

    def elevation_label(kind)
      kind == 'column' ? '柱脚の高さ Z (mm)' : "#{object_name(kind)}天端の高さ Z (mm)"
    end

    def initial_member(kind, system)
      if system == 'timber'
        role_id, role = Catalog.timber_roles(kind).first
        return Catalog.timber_params(kind, role_id, role.fetch('default_section'), 2700)
      end
      return Catalog.steel_params(Catalog.steel_default(kind), kind, 2700) if system == 'steel'

      prompts, keys = member_fields(kind)
      sizes = FRAMING.include?(kind) ? RC_SIZES.fetch(kind) : MEMBERS.fetch(kind).drop(1)
      member_params(prompts, keys, sizes).merge('system' => 'rc')
    end

    def steel_settings(kind, params, elevation, &apply)
      @steel_dialog&.close
      dialog = UI::HtmlDialog.new(dialog_title: "鉄骨造 #{object_name(kind)}の断面",
                                  preferences_key: 'Higeotoko.SbrArchitecture.Steel', width: 520, height: 485,
                                  resizable: true, style: UI::HtmlDialog::STYLE_DIALOG)
      dialog.set_file(File.join(__dir__, 'steel_picker.html'))
      dialog.add_action_callback('ready') do
        sections = Catalog.steel_options
        data = { sections: sections, section: params.fetch('section_id'), height: params['height'], elevation: elevation,
                 elevationLabel: elevation_label(kind), member: object_name(kind) }
        dialog.execute_script("setup(#{JSON.generate(data)})")
      end
      dialog.add_action_callback('apply') do |_context, section_id, height, z|
        report_errors do
          selected = Catalog.steel_params(Catalog.steel.fetch(section_id), kind, height)
          z = Layout.mm(z, elevation_label(kind)) if elevation
          dialog.close
          apply.call(selected, z)
        end
      end
      dialog.set_on_closed { @steel_dialog = nil if @steel_dialog.equal?(dialog) }
      @steel_dialog = dialog
      dialog.show_modal
    end

    def start_member(kind, configure = false)
      report_errors do
        model = Sketchup.active_model
        top_level!(model)
        @member_defaults ||= {}
        system = FRAMING.include?(kind) ? structural_system(model) : 'rc'
        key = [kind, system]
        params, previous_z = @member_defaults[key] || [initial_member(kind, system), 0]
        level = active_level(model)
        z = level&.last || previous_z
        place = lambda do |selected, elevation|
          @member_defaults[key] = [selected, elevation] if configure
          model.select_tool(Placement.new(model, kind, attach_level(selected.dup, level, elevation), elevation))
        end
        if !configure
          place.call(params, z)
        elsif system == 'steel'
          steel_settings(kind, params, z, &place)
        elsif system == 'timber'
          result = timber_settings(kind, params, z)
          place.call(result.first, Layout.mm(result.last, elevation_label(kind))) if result
        else
          prompts, keys = member_fields(kind)
          values = UI.inputbox(prompts + [elevation_label(kind)], params.values_at(*keys) + [z], "#{object_name(kind)}の寸法")
          next unless values

          selected = params.merge(member_params(prompts, keys, values.first(keys.size)))
          foundation_section(selected) if kind == 'strip_foundation'
          place.call(selected, Layout.mm(values.last, elevation_label(kind)))
        end
      end
    end

    def levels(model)
      input = model.get_attribute(DICT, 'levels', DEFAULT_LEVELS)
      input.split(',').to_h do |item|
        name, elevation = item.split('=', 2)
        [name, Float(elevation)]
      end
    end

    def active_level(model)
      name = model.get_attribute(DICT, 'active_level', 'GL')
      return unless name

      elevation = levels(model)[name]
      [name, elevation] if elevation
    end

    def attach_level(params, level, elevation)
      params['level'] = level.first if level && level.last == elevation
      params
    end

    def choose_level
      report_errors do
        model = Sketchup.active_model
        top_level!(model)
        options = levels(model).map { |name, elevation| "#{name} (#{elevation} mm)" }
        options << '手入力'
        active = active_level(model)
        current = active ? "#{active.first} (#{active.last} mm)" : '手入力'
        values = UI.inputbox(['作図レベル'], [current], [options.join('|')], '作図レベルを選択')
        next unless values && values.first != current

        index = options.index(values.first)
        name = index == options.size - 1 ? '' : levels(model).keys.fetch(index)
        model.select_tool(nil)
        operation(model, '作図レベルを切替') { model.set_attribute(DICT, 'active_level', name) }
      end
    end

    def edit_levels
      report_errors do
        model = Sketchup.active_model
        top_level!(model)
        values = UI.inputbox(['レベル名=高さ (mm)'], [model.get_attribute(DICT, 'levels', DEFAULT_LEVELS)],
                             'レベルを設定（例 GL=0,1FL=450,2FL=3200）')
        next unless values

        pairs = Layout.normalize(values.first).split(',', -1).map do |item|
          name, elevation = item.split('=', 2).map(&:strip)
          unless name && !name.empty? && !name.match?(/[|=]/) && elevation
            raise ArgumentError, 'レベルは「GL=0,1FL=450」の形式で入力してください。'
          end
          [name, Layout.mm(elevation, name)]
        end
        if pairs.empty? || pairs.to_h.size != pairs.size
          raise ArgumentError, 'レベル名を重複させず、1つ以上指定してください。'
        end

        model.select_tool(nil)
        Follow.set_levels(model, pairs)
      end
    end

    def edit(group)
      report_errors do
        top_level!(group.model)
        raise ArgumentError, 'ロックを解除してから編集してください。' if group.locked?

        previous = JSON.parse(group.get_attribute(DICT, 'parameters'))
        kind = group.get_attribute(DICT, 'kind')
        case kind
        when 'wall'
          if previous['head'] || previous.fetch('layers', []).any?
            Palette.show(edit_selected: true)
            next
          end
          values = UI.inputbox(['壁厚 (mm)', '高さ (mm)', '壁芯からの寄せ'],
                               previous.values_at('thickness', 'height', 'alignment'),
                               ['', '', Layout::ALIGNMENTS.join('|')], '壁を編集')
          next unless values

          params = previous.merge(wall_params(*values))
        when 'grid'
          defaults = previous.values_at('x_spans', 'y_spans').map { |spans| spans.join(',') }
          defaults.concat(previous.values_at('x_label_spec', 'y_label_spec'))
          values = UI.inputbox(['X方向の間隔 (mm)', 'Y方向の間隔 (mm)', 'Xの符号', 'Yの符号'],
                               defaults, '通り芯を編集')
          next unless values

          params = previous.merge(grid_params(*values))
        else
          if previous['system'] == 'steel'
            steel_settings(kind, previous, nil) { |selected, _| apply_edit(group, previous, previous.merge(selected)) }
            next
          elsif previous['system'] == 'timber' && previous['section_id']
            result = timber_settings(kind, previous)
            apply_edit(group, previous, previous.merge(result.first)) if result
            next
          end
          prompts, keys = member_fields(kind)
          values = UI.inputbox(prompts, previous.values_at(*keys), "#{object_name(kind)}の断面を編集")
          next unless values

          params = previous.merge(member_params(prompts, keys, values))
        end
        apply_edit(group, previous, params)
      end
    end

    def apply_edit(group, previous, params)
      return if params == previous
      return unless UI.messagebox('グループ内部を再生成します。内部に直接加えた加工や変更は置き換わります。続けますか？', MB_YESNO) == IDYES

      regenerate(group, params)
    end

    class Placement
      def initialize(model, kind, params, elevation)
        @model = model
        @kind = kind
        @params = params
        @elevation = elevation.mm
        @input = Sketchup::InputPoint.new
        @points = []
      end

      def activate
        prompt
      end

      def resume(view)
        prompt
        view.invalidate
      end

      def deactivate(view)
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        @input.pick(view, x, y)
        @center_guide = ColumnCenters.pick(view, x, y)
        @cursor = cursor_on_plane(view, x, y)
        if @center_guide
          view.tooltip = '柱芯'
        elsif @input.valid? && @input.degrees_of_freedom < 3
          view.tooltip = @input.tooltip
        end
        view.invalidate
      end

      def cursor_on_plane(view, x, y)
        if @center_guide
          return Geom::Point3d.new(@center_guide.x, @center_guide.y, @elevation)
        end
        if @input.valid? && @input.degrees_of_freedom < 3
          p = @input.position
          return Geom::Point3d.new(p.x, p.y, @elevation)
        end
        Geom.intersect_line_plane(view.pickray(x, y), [Geom::Point3d.new(0, 0, @elevation), Z_AXIS])
      end

      def onLButtonDown(flags, x, y, view)
        onMouseMove(flags, x, y, view)
        return unless @cursor

        SbrArchitecture.report_errors do
          SbrArchitecture.top_level!(@model)
          if @kind == 'grid'
            SbrArchitecture.create(@model, 'grid', @params, @cursor)
            @model.select_tool(nil)
          elsif SbrArchitecture.point_member?(@kind)
            SbrArchitecture.create(@model, @kind, @params, @cursor)
          elsif MEMBERS.key?(@kind) && @points.any?
            origin = @points.first
            next if origin.distance(@cursor).to_mm < Layout::MIN_MM

            SbrArchitecture.create(@model, @kind, @params.merge('end' => relative_xy(@cursor, origin)), origin)
            @points.clear
            prompt
          elsif @points.empty? || @points.last.distance(@cursor).to_mm >= Layout::MIN_MM
            @points << @cursor
            prompt
          end
        end
      end

      def onReturn(view)
        minimum = @kind == 'slab' ? 3 : 2
        return unless %w[wall slab].include?(@kind) && @points.size >= minimum

        SbrArchitecture.report_errors do
          SbrArchitecture.top_level!(@model)
          origin = @points.first
          points = @points.map { |p| relative_xy(p, origin) }
          SbrArchitecture.create(@model, @kind, @params.merge('points' => points), origin)
          @model.select_tool(nil)
        end
        view.invalidate
      end

      def relative_xy(position, origin)
        [(position.x - origin.x).to_mm, (position.y - origin.y).to_mm]
      end

      def onCancel(reason, view)
        if reason.zero? && @points.any?
          @points.pop
          @cursor = nil
          prompt
          view.invalidate
        elsif reason.zero?
          @model.select_tool(nil)
        end
      end

      def draw(view)
        @input.draw(view) if @input.display?
        return unless @cursor

        view.draw_points([@center_guide], 9, 3, Sketchup::Color.new(0, 140, 124)) if @center_guide

        rgb = { 'timber' => [160, 91, 28], 'steel' => [22, 101, 180], 'rc' => [91, 81, 136] }
        view.drawing_color = Sketchup::Color.new(*rgb.fetch(@params['system'], [0, 128, 210]))
        view.line_width = 2
        if @kind == 'grid'
          draw_grid(view)
        elsif SbrArchitecture.point_member?(@kind)
          draw_member(view, @params, @cursor)
        elsif @points.any?
          vertices = @points + [@cursor]
          view.draw(GL_LINE_STRIP, vertices)
          origin = @points.first
          coordinates = vertices.map { |p| relative_xy(p, origin) }
          if @kind == 'wall'
            profiles = Layout.wall_profiles(coordinates, @params.fetch('thickness'), @params.fetch('alignment'))
            profiles.each { |profile| draw_profile(view, profile, origin, @params.fetch('height').mm) }
          elsif @kind == 'slab'
            outline = Layout.slab_outline(coordinates)
            draw_profile(view, outline, origin, -@params.fetch('thickness').mm)
          else
            return if origin.distance(@cursor).to_mm < Layout::MIN_MM

            draw_member(view, @params.merge('end' => coordinates.last), origin)
          end
        end
      rescue ArgumentError, Catalog::STEEL::Error
        # The centerline remains visible while hovering over an invalid endpoint.
      end

      def draw_member(view, params, origin)
        if params['system'] == 'steel'
          member = SbrArchitecture.steel_member(@kind, params)
          SbrArchitecture.steel_section_ends(member).each { |ends| draw_ends(view, ends, origin) }
        elsif @kind == 'strip_foundation'
          draw_ends(view, SbrArchitecture.foundation_ends(params), origin)
        else
          profile = SbrArchitecture.member_profile(@kind, params)
          size = params['height'] || params.fetch('depth')
          draw_profile(view, profile, origin, (@kind == 'column' ? size : -size).mm)
        end
      end

      def draw_ends(view, ends, origin)
        offset = origin - ORIGIN
        first, last = ends.map { |loop| loop.map { |p| p + offset } }
        view.draw(GL_LINE_LOOP, first)
        view.draw(GL_LINE_LOOP, last)
        view.draw(GL_LINES, first.zip(last).flat_map { |a, b| [a, b] })
      end

      def draw_profile(view, profile, origin, height)
        bottom = profile.map { |x, y| Geom::Point3d.new(origin.x + x.mm, origin.y + y.mm, origin.z) }
        top = bottom.map { |p| Geom::Point3d.new(p.x, p.y, p.z + height) }
        view.draw(GL_LINE_LOOP, bottom)
        view.draw(GL_LINE_LOOP, top)
        view.draw(GL_LINES, bottom.zip(top).flat_map { |a, b| [a, b] })
      end

      def draw_grid(view)
        x, y, z = @cursor.to_a
        xs = Layout.stations(@params.fetch('x_spans')).map { |distance| x + distance.mm }
        ys = Layout.stations(@params.fetch('y_spans')).map { |distance| y + distance.mm }
        lines = xs.flat_map { |station| [[station, ys.first, z], [station, ys.last, z]] }
        lines.concat(ys.flat_map { |station| [[xs.first, station, z], [xs.last, station, z]] })
        view.draw(GL_LINES, lines.map { |xyz| Geom::Point3d.new(*xyz) })
      end

      def grid_outline
        x, y, z = @cursor.to_a
        width = @params.fetch('x_spans').sum.mm
        depth = @params.fetch('y_spans').sum.mm
        [[x, y, z], [x + width, y, z], [x + width, y + depth, z], [x, y + depth, z]].map do |xyz|
          Geom::Point3d.new(*xyz)
        end
      end

      def getExtents
        bounds = Geom::BoundingBox.new
        model_bounds = @model.bounds
        bounds.add(model_bounds.min, model_bounds.max) if model_bounds.valid?
        bounds.add(@points) unless @points.empty?
        if @cursor
          if @kind == 'grid'
            bounds.add(grid_outline)
          else
            margin = (@params['height'] || @params['depth'] || @params['thickness'] ||
                      @params.values_at('rise', 'footing_thickness').compact.sum).mm
            width = (@params['footing_width'] || @params['width'] || @params['thickness'] || 0).mm * 4
            (@points + [@cursor]).each do |p|
              bounds.add(Geom::Point3d.new(p.x - width, p.y - width, p.z - margin),
                         Geom::Point3d.new(p.x + width, p.y + width, p.z + margin))
            end
          end
        end
        bounds
      end

      def prompt
        message = if @kind == 'grid'
                    '通り芯の原点（最初のX/Yの交点）をクリック。Escで終了。'
                  elsif SbrArchitecture.point_member?(@kind)
                    "#{SbrArchitecture.object_name(@kind)}の中心をクリックして配置。Escで終了。"
                  elsif MEMBERS.key?(@kind)
                    name = SbrArchitecture.object_name(@kind)
                    @points.empty? ? "#{name}芯の始点をクリック。" : "#{name}芯の終点をクリック。Escで始点を取り消し。"
                  elsif @kind == 'slab'
                    '床の外周を3点以上クリック。Enterで閉じて確定。Escで直前の点を戻す。'
                  elsif @points.empty?
                    '壁芯の始点をクリック。Escで終了。'
                  else
                    '次の芯点をクリック。Enterで壁を作成。Escで直前の点を戻す。'
                  end
        label = @params['level'] ? "#{@params['level']} " : ''
        sizes = if @kind == 'wall'
                  @params.values_at('thickness', 'height')
                elsif @kind == 'slab'
                  [@params.fetch('thickness')]
                elsif MEMBERS.key?(@kind)
                  @params.values_at('width', 'depth', 'height').compact
                end
        section = @params['section_id'] || (sizes&.any? && "#{sizes.map { |size| format('%g', size) }.join('×')} mm")
        if @kind == 'strip_foundation'
          stem = @params.values_at('width', 'rise').map { |value| format('%g', value) }.join('×')
          base = @params.values_at('footing_width', 'footing_thickness').map { |value| format('%g', value) }.join('×')
          section = "立上り #{stem} / 底盤 #{base} mm"
        end
        system = Catalog::SYSTEMS[@params['system']] if FRAMING.include?(@kind)
        info = [system, section, "#{label}Z=#{@elevation.to_mm.round(3)} mm", message].select { |item| item }
        Sketchup.set_status_text(info.join('  |  '), SB_PROMPT)
      end
    end

    def toolbar_command(name, icon, tip, &action)
      command = UI::Command.new(name, &action)
      command.small_icon = command.large_icon = File.join(__dir__, "#{icon}.svg")
      command.tooltip = tip
      command.status_bar_text = tip
      command
    end

    def choose_tool_settings
      options = { '壁' => 'wall', '柱' => 'column', '梁' => 'beam', '布基礎' => 'strip_foundation', '独立基礎' => 'pad_foundation' }
      current = Catalog::SYSTEMS.fetch(structural_system(Sketchup.active_model))
      values = UI.inputbox(['寸法を設定するツール'], [@settings_tool || '柱'], [options.keys.join('|')], "寸法・断面設定（#{current}）")
      return unless values

      @settings_tool = values.first
      kind = options.fetch(@settings_tool)
      kind == 'wall' ? start_wall(true) : start_member(kind, true)
    end

    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu(MENU_TITLE)
      toolbar = UI::Toolbar.new(MENU_TITLE)
      palette = toolbar_command('BIMパレット', 'palette', '階・構造・作図・編集を1画面で開く') { Palette.show }
      menu.add_item(palette)
      toolbar.add_item(palette)
      toolbar.add_separator
      menu.add_separator
      Catalog::SYSTEMS.each do |system, label|
        command = toolbar_command(label, system, "#{label}に切り替える。柱・梁の断面が切り替わります。") { change_system(system) }
        command.set_validation_proc { structural_system(Sketchup.active_model) == system ? MF_CHECKED : MF_UNCHECKED }
        menu.add_item(command)
        toolbar.add_item(command)
      end
      toolbar.add_separator
      menu.add_separator
      actions = [
        toolbar_command('作図レベル', 'level', '作図レベルを選択') { choose_level },
        toolbar_command('通り芯', 'grid', '通り芯の間隔を指定して原点をクリック') { start_grid },
        toolbar_command('壁', 'wall', '壁芯を連続クリック、Enterで確定') { start_wall },
        toolbar_command('柱', 'column', '柱芯をクリック') { start_member('column') },
        toolbar_command('梁', 'beam', '梁芯の始点と終点をクリック') { start_member('beam') },
        toolbar_command('布基礎', 'strip_foundation', '立上りと底盤を一体で生成。基礎芯の始点と終点をクリック') { start_member('strip_foundation') },
        toolbar_command('独立基礎', 'pad_foundation', '矩形の基礎底盤を作成。中心をクリック') { start_member('pad_foundation') },
        toolbar_command('寸法・断面設定', 'settings', '選んだツールの寸法や断面を設定') { choose_tool_settings },
        toolbar_command('図面・シーン', 'drawings', '階別平面、立面、断面を作成・更新') { Drawings.show }
      ]
      actions.each do |command|
        menu.add_item(command)
        toolbar.add_item(command)
      end
      toolbar.get_last_state == TB_NEVER_SHOWN ? toolbar.show : toolbar.restore
      menu.add_separator
      settings = menu.add_submenu('寸法・レベル設定')
      settings.add_item('壁の設定…') { start_wall(true) }
      (MEMBERS.keys - ['sill']).each do |kind|
        settings.add_item("#{object_name(kind)}の設定…") { start_member(kind, true) }
      end
      settings.add_item('レベル一覧を編集…') { edit_levels }
      menu.add_item('建築部材をIFC4で書き出し…') { report_errors { IfcExport.choose_file(Sketchup.active_model) } }
      menu.add_item('壁上端の納まりを更新') { report_errors { WallHeads.update(Sketchup.active_model) } }
      UI.add_context_menu_handler do |context|
        model = Sketchup.active_model
        selection = model.selection
        next unless selection.length == 1 && !model.active_path

        group = selection.first
        next unless group.is_a?(Sketchup::Group)

        kind = group.get_attribute(DICT, 'kind')
        next unless %w[wall grid slab].include?(kind) || MEMBERS.key?(kind)

        context.add_item("SketchBRep #{object_name(kind)}を編集…") do
          kind == 'slab' ? Palette.show(edit_selected: true) : edit(group)
        end
        context.add_item('SketchBRep 柱芯点を追加…') { ColumnCenters.update(group) } if kind == 'column'
        context.add_item('SketchBRep 壁上端の納まり…') { report_errors { WallHeads.pick(group) } } if kind == 'wall'
        if Follow::KINDS.include?(kind)
          label = kind == 'slab' ? 'SketchBRep 床を階に関連付け…' : 'SketchBRep 通り芯・階に関連付け…'
          context.add_item(label) { Follow.dialog(group) }
        end
      end
      file_loaded(__FILE__)
    end
  end
end
