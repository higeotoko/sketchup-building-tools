# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require_relative 'layout'
require_relative 'catalog'
require_relative 'openings'
require_relative 'plan_opening_pick'
require_relative 'composition'
require_relative 'follow'
require_relative 'wall_heads'
require_relative 'column_centers'
require_relative 'schedule'
require_relative 'grid_style'
require_relative 'column_cuts'
require_relative 'plan_linework'
require_relative 'framing_plan'
require_relative 'layer_hatches'
require_relative 'drawing_datums'
require_relative 'elevation_datums'
require_relative 'section_depth'
require_relative 'section_placement'
require_relative 'roof'
require_relative 'slab_openings'
require_relative 'stairs'
require_relative 'room_boundaries'
require_relative 'rooms'
require_relative 'work_view'
require_relative 'drawings'
require_relative 'drawing_schedules'
require_relative 'layout_sheets'
require_relative 'publication_sets'
require_relative 'layout_schedule_update'
require_relative 'ifc_export'
require_relative 'palette'

module Higeotoko
  module SbrArchitecture
    DICT = 'higeotoko.sbr_architecture'
    MENU_TITLE = 'SketchUPbuildingTool'
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

    def arrow_axis(key)
      { VK_RIGHT => :x, VK_LEFT => :y, VK_UP => :z }[key]
    end

    def axis_position(axis, anchor, cursor)
      x, y, z = anchor.to_a
      case axis
      when :x then Geom::Point3d.new(cursor.x, y, z)
      when :y then Geom::Point3d.new(x, cursor.y, z)
      when :z then Geom::Point3d.new(x, y, cursor.z)
      end
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
      nested = !profiles.one? || layers.any? || openings.values.flatten.any? do |opening|
        opening['sash'] || opening['window_type'] || Doors.filled?(opening)
      end
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
      Doors.write(group, params, profiles)
    end

    def write_wall_segment(group, params, profile, index, openings)
      if openings.key?(index) || Roof.roof_planes(params)
        Openings.write_segment(group, params, profile, index, openings.fetch(index, []))
      else
        write_prism(group, profile, 0, params.fetch('height'))
      end
    end

    def member_profile(kind, params)
      width = params.fetch('width')
      if point_member?(kind)
        x = width / 2.0
        y = params.fetch('depth') / 2.0
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

    def foundation_rings(params)
      points = params.fetch('points') { [[0, 0], params.fetch('end')] }
      section = foundation_section(params)
      width = params.fetch('footing_width')
      profiles = Layout.wall_profiles(points, width, '中央')
      ends = profiles.map { |left, right, _, _| [left, right] }
      ends << profiles.last.values_at(3, 2)
      ends.zip(points).map do |(left, right), center|
        section.map do |offset, z|
          x = center[0] + (left[0] - right[0]) * offset / width
          y = center[1] + (left[1] - right[1]) * offset / width
          point(x, y, z)
        end
      end
    end

    def write_strip(group, params)
      rings = foundation_rings(params)
      group.entities.build do |builder|
        unless rings.first == rings.last
          builder.add_face(rings.first.reverse)
          builder.add_face(rings.last)
        end
        rings.each_cons(2) do |start, finish|
          start.each_index do |i|
            j = (i + 1) % start.size
            builder.add_face([start[i], start[j], finish[j], finish[i]])
          end
        end
      end
      raise ArgumentError, '基礎を立体にできませんでした。' unless group.manifold?

      group.entities.grep(Sketchup::Edge).each do |edge|
        a, b = edge.faces
        edge.hidden = true if b && a.normal.samedirection?(b.normal)
      end
      group.entities.each { |entity| entity.layer = group.model.layers[0] }
    end

    def object_name(kind)
      return '壁' if kind == 'wall'
      return '通り芯' if kind == 'grid'
      return '床スラブ' if kind == 'slab'
      return '屋根' if kind == 'roof'
      return '直階段' if kind == 'stair'
      return '室' if kind == 'room'

      MEMBERS.fetch(kind).first
    end

    def generated_name(kind, params)
      return "屋根（#{Roof::TYPES.fetch(params.fetch('roof_type'))}）" if kind == 'roof'

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
      when 'roof' then Roof.write(group, params)
      when 'stair' then Stairs.write(group, params)
      when 'grid' then write_grid(group, params)
      when 'strip_foundation' then write_strip(group, params)
      else
        height = point_member?(kind) ? params.fetch('height') : params.fetch('depth')
        write_prism(group, member_profile(kind, params), kind == 'column' ? 0 : -height, height)
      end
      ColumnCenters.add(group, params) if kind == 'column'
    end

    def write_grid(group, params, labels: true)
      xs = Layout.stations(params.fetch('x_spans'))
      ys = Layout.stations(params.fetch('y_spans'))
      entities = group.entities
      extension = 360.0
      xs.zip(params.fetch('x_names')).each do |x, name|
        stations = [-extension] + ys + [ys.last + extension]
        stations.each_cons(2) { |a, b| GridStyle.add_axis(entities, point(x, a), point(x, b)) }
        [-extension, ys.last + extension].each { |y| entities.add_text(name, point(x, y)) } if labels
      end
      ys.zip(params.fetch('y_names')).each do |y, name|
        stations = [-extension] + xs + [xs.last + extension]
        stations.each_cons(2) { |a, b| GridStyle.add_axis(entities, point(a, y), point(b, y)) }
        [-extension, xs.last + extension].each { |x| entities.add_text(name, point(x, y)) } if labels
      end
      xs.each_cons(2) do |a, b|
        entities.add_dimension_linear(point(a, 0), point(b, 0), Geom::Vector3d.new(0, -720.mm, 0))
      end
      ys.each_cons(2) do |a, b|
        entities.add_dimension_linear(point(0, a), point(0, b), Geom::Vector3d.new(-720.mm, 0, 0))
      end
      entities.each { |entity| entity.layer = group.model.layers[0] }
      GridStyle.apply(group)
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
      Layout.wall_profile_for(params)
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
        if kind == 'roof' && params['level']
          target.set_attribute(DICT, 'follow', JSON.generate('level' => params['level']))
        end
        if kind == 'grid'
          Drawings.seed_from_grid(model)
          GridStyle.show_in_view(model)
        end
        target
      end
      model.selection.clear
      model.selection.add(group)
      group
    end

    def regenerate(group, params, placement: nil, refresh_plan: false)
      kind = group.get_attribute(DICT, 'kind')
      name = object_name(kind)
      operation(group.model, "#{name}を編集") do
        previous = JSON.parse(group.get_attribute(DICT, 'parameters'))
        target = placement || placement_for(group, kind, previous)
        Follow.update_grid(group, previous, params, target) if kind == 'grid'
        params = WallHeads.resolve(group, params, target) if kind == 'wall'
        result = rebuild(group, kind, params, previous, target)
        WallHeads.refresh(group.model, changed: kind == 'grid' ? nil : group)
        Stairs.refresh(group.model, host: group) if kind == 'slab'
        if refresh_plan && (plan = Openings::PlanPick.active_spec(group.model))
          Drawings.generate(group.model, [plan], within_operation: true)
        end
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
        Palette.show if configure
        Palette.instance.activate('wall')
      end
    end

    def start_grid
      report_errors { Palette.instance.activate('grid') }
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
        Palette.instance.set_context(system: system)
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
        palette = Palette.instance
        next palette.activate(kind) unless configure

        model = Sketchup.active_model
        top_level!(model)
        system = FRAMING.include?(kind) ? structural_system(model) : 'rc'
        params = palette.saved_defaults(model, kind, system) || initial_member(kind, system)
        z = draw_elevation(model)
        place = lambda do |selected, elevation|
          palette.set_context(level: '', z: elevation) if elevation != z
          palette.store_defaults(model, kind, system, selected)
          palette.activate(kind)
        end
        if system == 'steel'
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

    def draw_elevation(model)
      active_level(model)&.last || model.get_attribute(DICT, 'manual_z', 0)
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
        Palette.instance.set_context(level: name)
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
          Palette.show(edit_selected: true)
          next
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
      def active?
        @active
      end

      def initialize(model, kind, params, elevation)
        @model = model
        @kind = kind
        @params = params
        @elevation = elevation.mm
        @input = Sketchup::InputPoint.new
        @points = []
      end

      def activate
        @active = true
        prompt
      end

      def resume(view)
        activate
        view.invalidate
      end

      def deactivate(view)
        @active = false
        view.invalidate
      end

      def update_settings(params, elevation)
        @next_settings = [params, elevation.mm]
        apply_settings if @points.empty?
      end

      def apply_settings
        @params, @elevation = @next_settings if @next_settings
        @next_settings = @cursor = nil
        @axis = @axis_anchor = nil
        prompt
        @model.active_view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        @mouse = [x, y]
        @input.pick(view, x, y)
        @center_guide = ColumnCenters.pick(view, x, y)
        free = cursor_on_plane(view, x, y)
        @cursor = @axis ? locked_cursor(view, x, y, free) : free
        if closes_at_start? && @cursor && @points.size >= 3 && @points.first != @points.last
          screen = view.screen_coords(@points.first)
          if Math.hypot(screen.x - x, screen.y - y) <= 8 && @axis != :z &&
             (!@axis || SbrArchitecture.axis_position(@axis, @points.last, @points.first) == @points.first)
            @cursor = @points.first
          end
        end
        if @axis
          view.tooltip = "#{@axis.to_s.upcase}軸固定"
        elsif @center_guide
          view.tooltip = '柱芯'
        elsif @input.valid? && @input.degrees_of_freedom < 3
          view.tooltip = @input.tooltip
        end
        prompt if @axis == :z
        view.invalidate
      end

      def closes_at_start?
        @kind == 'strip_foundation' || (@kind == 'wall' && @params['alignment'] == Layout::ECCENTRIC)
      end

      def cursor_on_plane(view, x, y)
        elevation = @points.first&.z || @elevation
        if @center_guide
          return Geom::Point3d.new(@center_guide.x, @center_guide.y, elevation)
        end
        if @input.valid? && @input.degrees_of_freedom < 3
          p = @input.position
          return Geom::Point3d.new(p.x, p.y, elevation)
        end
        Geom.intersect_line_plane(view.pickray(x, y), [Geom::Point3d.new(0, 0, elevation), Z_AXIS])
      end

      def locked_cursor(view, x, y, free)
        anchor = @axis == :z ? @axis_anchor : (@points.last || @axis_anchor)
        if @axis == :z
          ray = view.pickray(x, y)
          target = if @input.valid? && @input.degrees_of_freedom < 3
                     @input.position
                   elsif !ray.last.parallel?(Z_AXIS)
                     Geom.closest_points([anchor, Z_AXIS], ray).first
                   else
                     anchor
                   end
          return SbrArchitecture.axis_position(:z, anchor, target)
        end
        SbrArchitecture.axis_position(@axis, anchor, free) if free
      end

      def onKeyDown(key, repeat, flags, view)
        axis = SbrArchitecture.arrow_axis(key)
        return false unless axis
        return true if %w[slab_opening room].include?(@kind) && axis == :z
        return true if repeat > 1

        if @axis == axis
          @axis = @axis_anchor = nil
        elsif (anchor = @cursor || @points.last)
          @axis, @axis_anchor = axis, anchor
        end
        onMouseMove(flags, *@mouse, view) if @mouse
        prompt
        true
      end

      def params_at(origin)
        return @params if (origin.z - @elevation).abs < 0.001.mm

        @params.reject { |key, _| key == 'level' }
      end

      def rebase_path
        return unless @axis == :z && @cursor

        @points = @points.map { |point| SbrArchitecture.axis_position(:z, point, @cursor) }
        @axis = @axis_anchor = nil
      end

      def onLButtonDown(flags, x, y, view)
        onMouseMove(flags, x, y, view)
        return unless @cursor

        SbrArchitecture.report_errors do
          SbrArchitecture.top_level!(@model)
          rebase_path
          if @kind == 'grid'
            SbrArchitecture.create(@model, 'grid', params_at(@cursor), @cursor)
            @model.select_tool(nil)
          elsif SbrArchitecture.point_member?(@kind)
            SbrArchitecture.create(@model, @kind, params_at(@cursor), @cursor)
            prompt
          elsif @kind == 'roof' && @points.any?
            origin = @points.first
            SbrArchitecture.create(@model, @kind, params_at(origin).merge('end' => relative_xy(@cursor, origin)), origin)
            @model.select_tool(nil)
          elsif @kind == 'slab_opening' && @points.any?
            SlabOpenings.add(opening_host, @points.first, @cursor)
            @model.select_tool(nil)
          elsif @kind == 'room'
            seed = @cursor.to_a.first(2).map { |coordinate| coordinate.to_mm.round(3) }
            Rooms.dialog(@model, @params.fetch('level'), seed)
            @model.select_tool(nil)
          elsif MEMBERS.key?(@kind) && @kind != 'strip_foundation' && @points.any?
            origin = @points.first
            next if origin.distance(@cursor).to_mm < Layout::MIN_MM

            SbrArchitecture.create(@model, @kind, params_at(origin).merge('end' => relative_xy(@cursor, origin)), origin)
            @points.clear
            apply_settings
          elsif @points.empty? || @points.last.distance(@cursor).to_mm >= Layout::MIN_MM
            @points << @cursor
            return onReturn(view) if closes_at_start? && @points.size >= 4 && @points.last == @points.first

            prompt
          end
        end
      end

      def onReturn(view)
        minimum = @kind == 'slab' ? 3 : 2
        return unless %w[wall slab strip_foundation].include?(@kind) && @points.size >= minimum

        SbrArchitecture.report_errors do
          SbrArchitecture.top_level!(@model)
          rebase_path
          origin = @points.first
          points = @points.map { |p| relative_xy(p, origin) }
          SbrArchitecture.create(@model, @kind, params_at(origin).merge('points' => points), origin)
          @model.select_tool(nil)
        end
        view.invalidate
      end

      def relative_xy(position, origin)
        [(position.x - origin.x).to_mm, (position.y - origin.y).to_mm]
      end

      def opening_host
        slab = @model.find_entity_by_persistent_id(@params.fetch('host_id'))
        raise ArgumentError, '選択した床がなくなりました。床を選び直してください。' unless slab&.valid?

        slab
      end

      def onCancel(reason, view)
        if reason.zero? && @axis
          @axis = @axis_anchor = nil
          onMouseMove(0, *@mouse, view) if @mouse
          prompt
        elsif reason.zero? && @points.any?
          @points.pop
          if @points.empty?
            apply_settings
          else
            @cursor = nil
            prompt
            view.invalidate
          end
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
          vertices = vertices.map { |point| SbrArchitecture.axis_position(:z, point, @cursor) } if @axis == :z
          view.draw(GL_LINE_STRIP, vertices)
          origin = vertices.first
          coordinates = vertices.map { |p| relative_xy(p, origin) }
          if @kind == 'wall'
            profiles = SbrArchitecture.wall_profiles(@params.merge('points' => coordinates))
            profiles.each { |profile| draw_profile(view, profile, origin, @params.fetch('height').mm) }
          elsif @kind == 'slab'
            outline = Layout.slab_outline(coordinates)
            draw_profile(view, outline, origin, -@params.fetch('thickness').mm)
          elsif @kind == 'roof'
            draw_ends(view, Roof.solid_ends(@params.merge('end' => coordinates.last)), origin)
          elsif @kind == 'slab_opening'
            slab = opening_host
            points = vertices.map { |point| point.transform(slab.transformation.inverse).to_a.first(2).map(&:to_mm) }
            ring = SlabOpenings.rectangle(*points).map { |xy| SbrArchitecture.point(*xy).transform(slab.transformation) }
            view.draw(GL_LINE_LOOP, ring)
          elsif @kind == 'strip_foundation'
            coordinates.pop if coordinates.size > 1 && coordinates[-1] == coordinates[-2]
            if coordinates.size >= 2
              rings = SbrArchitecture.foundation_rings(@params.merge('points' => coordinates))
              rings.each_cons(2) { |start, finish| draw_ends(view, [start, finish], origin) }
            end
          else
            return if origin.distance(@cursor).to_mm < Layout::MIN_MM

            draw_member(view, @params.merge('end' => coordinates.last), origin)
          end
        end
        draw_axis(view) if @axis
      rescue ArgumentError, Catalog::STEEL::Error
        # The centerline remains visible while hovering over an invalid endpoint.
      end

      def draw_axis(view)
        rgb = { x: [201, 39, 49], y: [25, 138, 68], z: [29, 107, 207] }
        color = Sketchup::Color.new(*rgb.fetch(@axis))
        anchor = @axis == :z ? @axis_anchor : (@points.last || @axis_anchor)
        view.drawing_color = color
        view.draw(GL_LINES, [anchor, @cursor]) if anchor.distance(@cursor) >= Layout::MIN_MM.mm
        view.draw_points([@cursor], 8, 3, color)
      end

      def draw_member(view, params, origin)
        if params['system'] == 'steel'
          member = SbrArchitecture.steel_member(@kind, params)
          SbrArchitecture.steel_section_ends(member).each { |ends| draw_ends(view, ends, origin) }
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
          elsif @kind == 'roof' && @points.any?
            origin = @points.first
            if [(origin.x - @cursor.x).abs, (origin.y - @cursor.y).abs].all? { |span| span >= Layout::MIN_MM.mm }
              ends = Roof.solid_ends(@params.merge('end' => relative_xy(@cursor, origin)))
              bounds.add(ends.flatten.map { |point| point + (origin - ORIGIN) })
            end
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
                  elsif @kind == 'strip_foundation'
                    '基礎芯を連続クリック。Enterで確定、始点をクリックで一周。Escで直前の点を戻す。'
                  elsif MEMBERS.key?(@kind)
                    name = SbrArchitecture.object_name(@kind)
                    @points.empty? ? "#{name}芯の始点をクリック。" : "#{name}芯の終点をクリック。Escで始点を取り消し。"
                  elsif @kind == 'slab'
                    '床の外周を3点以上クリック。Enterで閉じて確定。Escで直前の点を戻す。'
                  elsif @kind == 'roof'
                    @points.empty? ? '屋根を掛ける外壁矩形の角をクリック。' : '対角をクリックして屋根を作成。Escで戻す。'
                  elsif @kind == 'slab_opening'
                    @points.empty? ? '床開口の角をクリック。' : '対角をクリックして床開口を作成。Escで戻す。'
                  elsif @kind == 'room'
                    '室の内側をクリックして室名と面積を登録。既存の室もここから編集。'
                  elsif @points.empty?
                    '壁芯の始点をクリック。Escで終了。'
                  else
                    '次の芯点をクリック。Enterで壁を作成。Escで直前の点を戻す。'
                  end
        elevation = @axis == :z && @cursor ? @cursor.z : (@points.first&.z || @elevation)
        level = @params['level'] if (elevation - @elevation).abs < 0.001.mm
        label = level ? "#{level} " : ''
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
        axis = @axis && "#{@axis.to_s.upcase}軸固定（同じ矢印で解除）"
        info = [system, section, "#{label}Z=#{elevation.to_mm.round(3)} mm", axis, message].compact
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
        toolbar_command('布基礎', 'strip_foundation', '基礎芯を連続クリック。Enterまたは始点クリックで確定') { start_member('strip_foundation') },
        toolbar_command('独立基礎', 'pad_foundation', '矩形の基礎底盤を作成。中心をクリック') { start_member('pad_foundation') },
        toolbar_command('床スラブ', 'slab', '床の外周をクリック。Enterで閉じる') { report_errors { Palette.instance.activate('slab') } },
        toolbar_command('屋根', 'roof', '外壁矩形の対角を2点クリックして片流れ・切妻を作る') { report_errors { Palette.instance.activate('roof') } },
        toolbar_command('床開口', 'slab_opening', '床を選び、矩形の対角を2点クリック') { report_errors { Palette.instance.activate('slab_opening') } },
        toolbar_command('直階段', 'stair', '上階の床開口と下階レベルを選び、直階段を作る') { report_errors { Palette.instance.activate('stair') } },
        toolbar_command('室', 'room', '閉じた壁の内側をクリックして室名・面積を登録') { report_errors { Palette.instance.activate('room') } },
        toolbar_command('窓開口', 'window', '形式を選んで壁に配置。必要に応じて可動側を指定') { report_errors { Palette.instance.activate('window') } },
        toolbar_command('扉開口', 'door', '形式を選んで壁に配置。必要に応じて引く方向・開く側を指定') { report_errors { Palette.instance.activate('door') } },
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
      menu.add_item('作業背景を切り替え') { report_errors { WorkView.toggle(Sketchup.active_model) } }
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
        if kind == 'stair'
          context.add_item('SketchUPbuildingTool 直階段を編集…') { report_errors { Stairs.dialog(model, group) } }
          next
        end
        if kind == 'room'
          context.add_item('SketchUPbuildingTool 室情報を編集…') { report_errors { Rooms.edit(group) } }
          next
        end
        next unless %w[wall grid slab roof].include?(kind) || MEMBERS.key?(kind)

        context.add_item("SketchUPbuildingTool #{object_name(kind)}を編集…") do
          %w[slab roof].include?(kind) ? Palette.show(edit_selected: true) : edit(group)
        end
        context.add_item('SketchUPbuildingTool 柱芯点を追加…') { ColumnCenters.update(group) } if kind == 'column'
        context.add_item('SketchUPbuildingTool 壁上端の納まり…') { report_errors { WallHeads.pick(group) } } if kind == 'wall'
        context.add_item('SketchUPbuildingTool 床開口を編集…') { report_errors { SlabOpenings.edit(group) } } if kind == 'slab'
        if Follow::KINDS.include?(kind)
          label = %w[slab roof].include?(kind) ? "#{MENU_TITLE} #{object_name(kind)}を階に関連付け…" : "#{MENU_TITLE} 通り芯・階に関連付け…"
          context.add_item(label) { Follow.dialog(group) }
        end
      end
      file_loaded(__FILE__)
    end
  end
end
