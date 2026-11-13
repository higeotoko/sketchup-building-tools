# frozen_string_literal: true

require 'set'
require 'securerandom'
require 'digest'
require 'json'
require_relative 'plan_range'
require_relative 'plan_crop'
require_relative 'plan_crop_placement'
require_relative 'plan_references'
require_relative 'plan_dimensions'
require_relative 'plan_dimension_placement'
require_relative 'member_tags'
require_relative 'member_tag_placement'

module Higeotoko
  module SbrArchitecture
    module Drawings
      API = SbrArchitecture
      META = 'higeotoko.sbr_architecture.drawing'
      SIDES = {
        'x+' => ['＋X側', [1, 0, 0]], 'x-' => ['−X側', [-1, 0, 0]],
        'y+' => ['＋Y側', [0, 1, 0]], 'y-' => ['−Y側', [0, -1, 0]]
      }.freeze
      CLOCKWISE = %w[y+ x+ y- x-].freeze
      COMPASS = %w[北 東 南 西].freeze
      FLAGS = PAGE_USE_CAMERA | PAGE_USE_SECTION_PLANES | PAGE_USE_LAYER_VISIBILITY |
              PAGE_USE_HIDDEN_OBJECTS | PAGE_USE_RENDERING_OPTIONS
      VIEW_OPTIONS = {
        'DisplaySectionPlanes' => false, 'DisplaySketchAxes' => false,
        'HideConstructionGeometry' => true, 'SectionCutFilled' => true, 'SectionCutDrawEdges' => true,
        'DisplaySky' => false, 'DisplayGround' => false, 'DrawGround' => false, 'DrawHorizon' => false,
        'DisplayFog' => false, 'DrawProfiles' => false,
        'EdgeColorMode' => 0, 'EdgeType' => 0, 'EdgeDisplayMode' => 1, 'RenderMode' => 1,
        'DisplayColorByLayer' => false, 'DrawSilhouettes' => false, 'DrawProfilesOnly' => false, 'DrawDepthQue' => false
      }.freeze
      module_function

      def specs(model)
        model.pages.filter_map do |page|
          raw = page.get_attribute(META, 'spec')
          [page, JSON.parse(raw)] if raw
        end
      end

      def source_signature(model)
        objects = model.entities.grep(Sketchup::Drawingelement).filter_map do |entity|
          next if entity.layer.get_attribute(META, 'key')

          source = case entity
                   when Sketchup::Group, Sketchup::ComponentInstance
                     kind = Follow.kind(entity) if entity.is_a?(Sketchup::Group)
                     data = kind ? [kind, entity.get_attribute(API::DICT, 'parameters')] : entity.definition.guid
                     [entity.transformation.to_a.map(&:to_f), data]
                   when Sketchup::Edge, Sketchup::Face
                     entity.vertices.map { |vertex| vertex.position.to_a.map(&:to_f) }.sort
                   when Sketchup::Image
                     entity.transformation.to_a.map(&:to_f)
                   end
          [entity.persistent_id, entity.layer.name, source] if source
        end
        units = model.options['UnitsOptions']
        Digest::SHA256.hexdigest(JSON.generate([API.levels(model), units['LengthUnit'], units['LengthFormat'],
                                                objects.sort_by(&:first)]))
      end

      def section_key(model, input, name)
        sections = specs(model).map(&:last).select { |item| item['kind'] == 'section' }
        named = sections.find { |item| item['name'] == name }
        if input['key']
          selected = sections.find { |item| item['key'] == input['key'] }
          raise ArgumentError, '編集する断面がありません。図面一覧から選び直してください。' unless selected
          raise ArgumentError, "断面名「#{name}」は使用済みです。" if named && named != selected

          return selected.fetch('key')
        end
        return named.fetch('key') if named

        key = "section:#{name}"
        sections.any? { |item| item['key'] == key } ? "section:#{SecureRandom.uuid}" : key
      end

      def plan_identity(model, input, level)
        standard = "plan:#{level}"
        key = input['key']
        return { 'key' => standard } if !input.key?('plan_name') && (key.nil? || key == standard)

        name = input['plan_name'].to_s.strip
        if name.empty? || name.length > 32 || name.match?(/[[:cntrl:]]/)
          raise ArgumentError, '平面の名前を32文字以内で入力してください。'
        end
        plans = specs(model).filter_map do |_, item|
          item if item['kind'] == 'plan' && item['level'] == level && item['plan_name']
        end
        if key && plans.none? { |item| item['key'] == key }
          raise ArgumentError, '編集する平面がこの階にありません。対象を選び直してください。'
        end
        if plans.any? { |item| item['key'] != key && item.fetch('plan_name').casecmp?(name) }
          raise ArgumentError, "この階では「#{name}」の名前が使用済みです。"
        end

        { 'key' => key || "plan-view:#{SecureRandom.uuid}", 'plan_name' => name }
      end

      def spec(model, input)
        kind = input.fetch('kind')
        data = case kind
        when 'plan'
          level = input.fetch('level')
          raise ArgumentError, "作図レベル「#{level}」がありません。" unless API.levels(model).key?(level)

          cut = Layout.mm(input['cut'], '床面からの切断高さ', positive: true)
          identity = plan_identity(model, input, level)
          crop = PlanCrop.settings(input, named: identity.key?('plan_name'))
          identity.merge(PlanRange.settings(input, cut), crop, PlanReferences.settings(input, identity, crop['plan_crop']),
                                                  'kind' => kind, 'level' => level, 'cut' => cut,
                                                  'hatch' => input['hatch'] == true,
                                                  'opening_dimensions' => input['opening_dimensions'] == true)
        when 'framing'
          level = input.fetch('level')
          raise ArgumentError, "作図レベル「#{level}」がありません。" unless API.levels(model).key?(level)

          offset = Layout.mm(input.fetch('top_offset', 0), '梁天端のオフセット')
          tolerance = Layout.mm(input.fetch('top_tolerance', 150), '梁天端の許容範囲', positive: true)
          { 'key' => "framing:#{level}", 'kind' => kind, 'level' => level, 'top_offset' => offset,
            'top_tolerance' => tolerance, 'beam_labels' => input.fetch('beam_labels', true) == true }
        when 'elevation'
          side = input.fetch('side')
          SIDES.fetch(side)
          elevation = { 'key' => "elevation:#{side}", 'kind' => kind, 'side' => side,
                        'direction_label' => compass(north_side(model), side), 'opening_heights' => input['opening_heights'] == true }
          { 'eave' => '軒高', 'ridge' => '棟高' }.each do |key, label|
            elevation[key] = Layout.mm(input[key], label) unless input[key].to_s.strip.empty?
          end
          if elevation['eave'] && elevation['ridge'] && elevation['eave'] > elevation['ridge']
            raise ArgumentError, '棟高は軒高以上にしてください。'
          end
          elevation
        when 'section'
          name = input['name'].to_s.strip
          raise ArgumentError, '断面に名前を入力してください。' if name.empty? || name.length > 40

          side = input.fetch('side')
          SIDES.fetch(side)
          offset = Layout.mm(input['offset'], '断面の座標')
          section = { 'key' => section_key(model, input, name), 'kind' => kind, 'name' => name, 'side' => side, 'offset' => offset }
          section['storey_dimensions'] = input.fetch('storey_dimensions', true) == true
          section.merge!(input.slice('beam_id', 'beam_level')) if input['beam_id']
          section['depth'] = Layout.mm(input['depth'], '見通しの奥行き', positive: true) unless input['depth'].to_s.strip.empty?
          section
        else
          raise ArgumentError, '図面の種類を選択してください。'
        end
        data.merge('scale' => scale_value(input['scale']))
      end

      def scale_value(value)
        return if value.to_s.empty? || value == 'auto'

        number = Integer(value.to_s, 10)
        raise ArgumentError, '図面の縮尺を選んでください。' unless LayoutSheets::SCALES.include?(number)

        number
      end

      def title(data)
        case data.fetch('kind')
        when 'plan' then ["平面 #{data.fetch('level')}", data['plan_name']].compact.join('｜')
        when 'framing' then "梁伏図 #{data.fetch('level')}"
        when 'elevation'
          data['direction_label'] ? "#{data.fetch('direction_label')}立面図" : "立面 #{SIDES.fetch(data.fetch('side')).first}"
        when 'section' then "断面 #{data.fetch('name')}"
        end
      end

      def north_side(model)
        model.get_attribute(META, 'north_side', '')
      end

      def compass(north, side)
        index = CLOCKWISE.index(north)
        COMPASS[(CLOCKWISE.index(side) - index) % CLOCKWISE.length] if index
      end

      def make_elevation(model, input)
        north = input.fetch('north_side', north_side(model))
        raise ArgumentError, '北の方位を選んでください。' unless north == '' || SIDES.key?(north)
        return generate(model, [input]).first if north == north_side(model)

        others = specs(model).filter_map do |_, data|
          data if data['kind'] == 'elevation' && data['side'] != input['side']
        end
        API.operation(model, '立面の方位を設定・更新') do
          model.set_attribute(META, 'north_side', north)
          generate(model, [input, *others], within_operation: true).first
        end
      end

      def sheet_label(number)
        format('A-%02d', number) if number
      end

      def assign_sheet_numbers(model, existing, keys)
        numbers = existing.to_h { |page, item| [item.fetch('key'), page.get_attribute(META, 'sheet_number')] }.compact
        last = ([model.get_attribute(META, 'last_sheet_number', 0)] + numbers.values).max
        keys.each { |key| numbers[key] ||= (last += 1) }
        numbers
      end

      def section_targets(data, numbers)
        data.filter_map do |item|
          item.merge('sheet' => sheet_label(numbers.fetch(item.fetch('key')))) if item['kind'] == 'section'
        end
      end

      def section_references(sections)
        rows = sections.sort_by { |item| item.fetch('key') }.map { |item| item.values_at('key', 'name', 'side', 'offset', 'sheet') }
        rows.unshift('cut-line-v1') unless rows.empty?
        JSON.generate(rows)
      end

      def plan_needs_update?(page, references)
        page.get_attribute(META, 'plan_projected_walls').nil? ||
          page.get_attribute(META, 'plan_grid_bubbles').nil? ||
          page.get_attribute(META, 'section_references') != references
      end

      def seed_from_grid(model)
        existing = specs(model).map { |_, data| data.fetch('key') }.to_set
        levels = API.levels(model).keys
        floors = levels.reject { |name| name == 'GL' }
        floors = levels if floors.empty?
        plans = floors.map { |level| { 'kind' => 'plan', 'level' => level, 'cut' => 1100 } }
        elevations = SIDES.keys.map { |side| { 'kind' => 'elevation', 'side' => side } }
        inputs = (plans + elevations).reject { |item| existing.include?(spec(model, item).fetch('key')) }
        generate(model, inputs, within_operation: true, provisional: true)
      end

      def native_section_input(model)
        selected = model.selection.grep(Sketchup::SectionPlane).select { |item| model.entities.include?(item) }
        plane = selected.one? ? selected.first : model.entities.active_section_plane
        raise ArgumentError, 'ルートでSketchUpの縦断面を有効にするか、断面平面を選択してください。' unless plane

        x, y, z, d = plane.get_plane
        components = [x, y, z]
        axis = components.each_index.max_by { |i| components[i].abs }
        normal = components[axis]
        unless axis < 2 && normal.abs > 0.000001 &&
               components.each_with_index.all? { |value, i| i == axis || value.abs < normal.abs * 0.000001 }
          raise ArgumentError, '取り込めるのはX方向またはY方向を向く縦断面です。'
        end

        side = %w[x y][axis] + (normal.negative? ? '+' : '-')
        { side: side, offset: (-d / normal).to_mm.round(6) }
      end

      def tags(model)
        model.layers.select { |layer| layer.get_attribute(META, 'key') }
      end

      def find_asset(entities, type, key)
        entities.grep(type).find { |item| item.get_attribute(META, 'key') == key }
      end

      def annotation_tag(model, key, label)
        found = tags(model).find { |layer| layer.get_attribute(META, 'key') == key }
        return found if found

        base = "SBT 図面注記｜#{label}"
        name = base
        suffix = 1
        while model.layers[name]
          suffix += 1
          name = "#{base} #{suffix}"
        end
        tag = model.layers.add(name)
        tag.set_attribute(META, 'key', key)
        tag.page_behavior = LAYER_HIDDEN_BY_DEFAULT | LAYER_IS_HIDDEN_ON_NEW_PAGES
        tag.visible = false
        tag
      end

      def annotate(model, data, height, hidden, plan_sections, framing_beams: nil, range_bottom: nil)
        key = data.fetch('key')
        tag = annotation_tag(model, key, title(data))
        annotation = find_asset(model.entities, Sketchup::Group, key) || model.entities.add_group
        annotation.locked = false
        annotation.make_unique
        raise ArgumentError, '既存の図面注記を更新できません。' unless annotation.entities.clear!

        annotation.name = "#{title(data)}｜図面注記"
        annotation.layer = tag
        annotation.transformation = IDENTITY
        annotation.set_attribute(META, 'key', key)
        if framing_beams
          stats, grids, labels, masks = FramingPlan.draw(annotation, framing_beams, data.fetch('level'), height, hidden)
          return [annotation, stats, masks, [], grids, labels]
        end
        return [annotation, {}, [], [], []] unless height

        columns = ColumnCuts.sections(model, height, hidden)
        masks = ColumnCuts.masks(columns)
        hollow = ColumnCuts.masks(columns.select { |_, loops, _| loops.size > 1 })
        stats, walls, grids = PlanLinework.populate(annotation, data.fetch('level'), height, hidden, masks: masks,
                                             hollow_masks: hollow, dimension_openings: data['opening_dimensions'],
                                             sections: plan_sections, dimension_overall: !data.key?('plan_crop'))
        level = data.fetch('level')
        stats[:stairs] = Stairs.draw_plan(annotation.entities, model, level, height, hidden)
        stats[:floor_openings] = SlabOpenings.draw_plan(annotation.entities, model, level, height, hidden, bottom: range_bottom)
        ColumnCuts.draw(annotation.entities, columns, height)
        [annotation, stats.merge(column_cuts: columns.size, section_marks: 0), masks, walls, grids]
      end

      def geometry(model, data)
        kind = data.fetch('kind')
        if kind == 'plan'
          level = API.levels(model).fetch(data.fetch('level'))
          height = level + data.fetch('cut')
          return [Z_AXIS, Y_AXIS, API.point(0, 0, height), height]
        end
        if kind == 'framing'
          height = API.levels(model).fetch(data.fetch('level')) + data.fetch('top_offset')
          return [Z_AXIS, Y_AXIS, nil, height]
        end
        side = data.fetch('side')
        _, coords = SIDES.fetch(side)
        direction = Geom::Vector3d.new(coords)
        point = if kind == 'section'
                  offset = data.fetch('offset')
                  side.start_with?('x') ? API.point(offset, 0) : API.point(0, offset)
                end
        [direction, Z_AXIS, point, nil]
      end

      def section_plane(model, data, point, eye_direction)
        return unless point

        key = data.fetch('key')
        normal = eye_direction.reverse
        plane = find_asset(model.entities, Sketchup::SectionPlane, key)
        if plane
          plane.set_plane([point, normal])
        else
          plane = model.entities.add_section_plane(point, normal)
        end
        raise ArgumentError, '断面平面を作成できませんでした。' unless plane

        plane.set_attribute(META, 'key', key)
        plane.name = "SBT｜#{title(data)}"
        plane.layer = model.layers[0]
        plane
      end

      def bounds(model, annotation_tag, hidden, base: nil, allow_empty: false)
        box = Geom::BoundingBox.new
        box.add(base.min, base.max) if base
        model.entities.each do |entity|
          next unless entity.respond_to?(:bounds) && !entity.is_a?(Sketchup::SectionPlane)
          next if entity.respond_to?(:hidden?) &&
                  (hidden.key?(entity.persistent_id) ? hidden.fetch(entity.persistent_id) : entity.hidden?)
          next if entity.respond_to?(:layer) && entity.layer.get_attribute(META, 'key') && entity.layer != annotation_tag
          next if entity.respond_to?(:layer) && !entity.layer.visible? && entity.layer != annotation_tag

          inner = entity.bounds
          box.add(inner.min, inner.max) if inner.valid?
        end
        if !box.valid? || box.diagonal.to_mm < 1
          return nil if allow_empty

          raise ArgumentError, '図面にする形状がありません。'
        end

        box
      end

      def provisional_bounds(model, groups)
        box = Geom::BoundingBox.new
        groups.each do |group|
          next unless Follow.kind(group) == 'grid'

          limits = group.bounds
          box.add(limits.min, limits.max) if limits.valid?
        end
        raise ArgumentError, '図面にする形状または通り芯を置いてください。' unless box.valid?

        low, high = API.levels(model).values.minmax
        box.add(Geom::Point3d.new(box.min.x, box.min.y, low.mm), Geom::Point3d.new(box.max.x, box.max.y, high.mm))
        box
      end

      def view_size(box, direction, up)
        points = 8.times.map { |index| box.corner(index) }
        [up.cross(direction), up].map do |axis|
          low, high = points.map { |point| (point - ORIGIN).dot(axis) }.minmax
          high - low
        end
      end

      def camera(view, box, direction, up, size)
        width, height = size
        span = [box.diagonal.to_f, 1000.mm.to_f].max
        eye = box.center + Geom::Vector3d.new(direction.to_a.map { |value| value * span * 2 })
        result = Sketchup::Camera.new(eye, box.center, up, false)
        aspect = view.vpwidth.to_f / [view.vpheight, 1].max
        result.height = [height, width / [aspect, 0.1].max, 1000.mm.to_f].max * 1.18
        result
      end

      def managed_objects(model)
        groups, fills = [], []
        model.entities.grep(Sketchup::Group).each do |item|
          groups << item if Follow.kind(item)
          case Follow.kind(item)
          when 'wall'
            fills.concat(item.entities.grep(Sketchup::ComponentInstance).select { |part| part.get_attribute(API::DICT, 'opening_id') })
          end
        end
        [groups, fills]
      end

      def other_storey?(group, level, cut_height)
        assigned = Follow.parameters(group)['level']
        return false unless assigned && assigned != level

        box = group.bounds
        !(box.min.z.to_mm <= cut_height && cut_height < box.max.z.to_mm)
      end

      def outside_plan?(group, level, floor, cut)
        return true if Follow.kind(group) == 'stair'
        return other_storey?(group, level, cut) unless Follow.kind(group) == 'beam'

        box = group.bounds
        !box.valid? || box.max.z.to_mm <= floor || box.min.z.to_mm >= cut
      end

      def scaled_frame(model, tag, visibility, direction, up, choices, base: nil, crop: nil)
        result = nil
        choices.each do |denominator|
          annotation_masks = yield denominator
          framing = crop || bounds(model, tag, visibility, base: base)
          unless crop
            annotation_masks.each do |_, xs, ys|
              framing.add(Geom::Point3d.new(xs.first.mm, ys.first.mm, framing.min.z),
                          Geom::Point3d.new(xs.last.mm, ys.last.mm, framing.max.z))
            end
          end
          size = view_size(framing, direction, up)
          extent = size.map(&:to_mm)
          result = [framing, size, extent, denominator]
          break if LayoutSheets.fitting_scale(extent, denominator)
        end
        result
      end

      def drawing_style(model, kind, layered, limited: false)
        styles = model.styles
        key = "#{kind}#{layered ? ':layers' : ''}#{limited ? ':depth' : ''}"
        style = styles.find { |item| item.get_attribute(META, 'style') == key }
        if !style && styles.selected_style.respond_to?(:duplicate)
          style = styles.selected_style.duplicate
          label = { 'plan' => '平面', 'framing' => '梁伏図', 'section' => '断面', 'elevation' => '立面' }.fetch(kind)
          style.name = "SBT｜図面 #{label}#{layered ? ' 層別' : ''}#{limited ? ' 奥行き指定' : ''}"
          style.set_attribute(META, 'style', key)
        end
        styles.selected_style = style if style
        options = model.rendering_options
        VIEW_OPTIONS.each { |option, value| options[option] = value if options.keys.include?(option) }
        if limited || kind == 'framing'
          %w[DrawHidden ROPDrawHiddenGeometry ROPDrawHiddenObjects].each do |option|
            options[option] = false if options.keys.include?(option)
          end
        end
        options['DisplaySectionCuts'] = %w[plan section].include?(kind)
        options['SectionCutFilled'] = kind == 'section' && !layered
        options['SectionCutWidth'] = kind == 'section' ? 3 : 1
        options['SectionDefaultCutColor'] = Sketchup::Color.new(24, 24, 24)
        options['BackgroundColor'] = Sketchup::Color.new(255, 255, 255)
        options['ForegroundColor'] = Sketchup::Color.new(24, 24, 24)
        options['SectionDefaultFillColor'] = Sketchup::Color.new(202, 207, 212)
        styles.update_selected_style if style
      end

      def build(model, data, baseline, sections, number, depth_sources, framing_sources: [], partials: [], provisional: false)
        key = data.fetch('key')
        page, previous = specs(model).find { |_, saved| saved['key'] == key }
        direction, up, point, height = geometry(model, data)
        beam_plan = data['kind'] == 'framing'
        groups, fills = managed_objects(model)
        hidden = baseline.select { |_, flag| flag }.keys.to_set
        overhead = []
        if beam_plan
          framing_beams = FramingPlan.select_beams(groups, height, data.fetch('top_tolerance'), hidden)
          automatically_hidden = framing_sources + fills
        else
          floor = API.levels(model).fetch(data.fetch('level')) if height
          range_bottom = floor + data['plan_bottom'] if height && data.key?('plan_bottom')
          overhead = PlanRange.overhead_beams(groups, height, floor + data['plan_top'], hidden) if height && data.key?('plan_top')
          automatically_hidden = groups.select do |group|
            next true if %w[grid room].include?(Follow.kind(group))
            next false unless height

            range_bottom ? PlanRange.outside?(group, range_bottom, height) : outside_plan?(group, data.fetch('level'), floor, height)
          end
          automatically_hidden.concat(fills) if height
        end
        auto_ids = automatically_hidden.map(&:persistent_id).to_set
        visibility = baseline.dup
        auto_ids.each { |id| visibility[id] = true }
        beam = model.find_entity_by_persistent_id(data.fetch('beam_id')) if data['beam_id']
        clearance = if beam.is_a?(Sketchup::Group) && !hidden.include?(beam.persistent_id) && beam.layer.visible?
                      DrawingDatums.beam_clearance(beam, API.levels(model)[data['beam_level']], point, direction)
                    end
        if beam_plan
          base_box = FramingPlan.bounds(framing_beams)
          provisional = base_box.nil?
          if provisional && !page
            raise ArgumentError, '指定範囲に梁がありません。対象の階または梁天端の範囲を調整してください。'
          end
          base_box ||= bounds(model, nil, baseline, allow_empty: true) || provisional_bounds(model, groups)
        else
          overhead_box = FramingPlan.bounds(overhead) if overhead.any?
          base_box = bounds(model, nil, visibility, base: overhead_box, allow_empty: true) unless provisional
          provisional ||= base_box.nil?
          if provisional
            base_box = bounds(model, nil, baseline, allow_empty: true) if range_bottom
            base_box ||= provisional_bounds(model, groups)
          end
        end
        crop = PlanCrop.box(data['plan_crop'], base_box) if data.key?('plan_crop')
        plan_sections = height && !beam_plan && !crop ? DrawingDatums.sections_in_plan(sections, base_box) : []
        plan_partials = PlanReferences.for_plan(data, partials)
        annotation, stats, masks, walls, grids, labels = annotate(model, data, height, hidden, plan_sections,
                                                                  framing_beams: framing_beams, range_bottom: range_bottom)
        if plan_partials.any?
          reference_obstacles = annotation.entities.grep(Sketchup::Edge).map do |edge|
            edge.vertices.map { |vertex| PlanDimensions.xy(vertex.position) }
          end
        end
        dimensions = PlanDimensions.entries(page) if data['kind'] == 'plan'
        if dimensions&.any?
          stats[:plan_dimensions] = PlanDimensions.draw(annotation.entities, model, height, data, dimensions, hidden)
        end
        member_tags = height ? MemberTags.entries(page) : []
        if member_tags.any?
          ids = member_tags.map { |entry| entry.fetch('member_id') }.to_set
          tag_members = MemberTags.candidates(model, data, height, hidden, groups, ids: ids,
                                              framing: framing_beams, overhead: overhead)
        end
        plan_hidden = []
        unless walls.empty?
          # The native cut outline can draw through a column's plan mask. Keep
          # the projected geometry below the cut and use the masked wall outline.
          upper = height - 1.0
          upper = [upper, (height + range_bottom) / 2.0].max if range_bottom
          projection_limit = API.point(0, 0, upper)
          plan_hidden, = SectionDepth.new(projection_limit, Z_AXIS.reverse, 0, visibility, minimum_z: range_bottom)
                                     .apply(annotation, walls, name: '壁の平面投影')
          plan_hidden.each { |wall| visibility[wall.persistent_id] = true }
        end
        if range_bottom
          eligible = groups.select { |group| !visibility[group.persistent_id] && group.layer.visible? }
          clipped, = SectionDepth.new(API.point(0, 0, range_bottom), Z_AXIS, 0, visibility)
                                  .apply(annotation, eligible, name: '平面の表示下限')
          clipped.each { |group| visibility[group.persistent_id] = true }
          plan_hidden.concat(clipped)
        end
        stats[:provisional] = true if provisional
        if data['kind'] == 'elevation' && !provisional
          opening_levels = data['opening_heights'] ? ElevationDatums.openings(groups, direction, hidden) : []
          height_data = data.key?('eave') || data.key?('ridge') ? data : Roof.elevation_data(groups, hidden)
          elevation_levels = ElevationDatums.labels(opening_levels, height_data)
        end
        depth_hidden = []
        if data['depth']
          eligible = depth_sources.select { |item| !visibility[item.persistent_id] && item.layer.visible? }
          depth_hidden, depth_stats = SectionDepth.new(point, direction, data.fetch('depth'), visibility).apply(annotation, eligible)
          stats.merge!(depth_stats)
        end
        stats[:beam_clearance] = clearance ? (clearance[3] - clearance[2]).round(1) : 'unavailable' if data['beam_id']
        tag = annotation.layer
        frame_base = provisional || beam_plan ? base_box : overhead_box
        if !crop && (grids.any? || plan_sections.any?)
          plan_frame = bounds(model, tag, visibility, base: frame_base)
        end
        section = section_plane(model, data, point, direction)
        view = model.active_view
        markers = annotation.entities.add_group
        markers.layer = model.layers[0]
        choices = data['scale'] ? [data.fetch('scale')] : LayoutSheets::AUTO_SCALES
        framing, size, extent, denominator = scaled_frame(model, tag, visibility, direction, up, choices,
                                                          base: frame_base, crop: crop) do |ratio|
          markers.entities.clear!
          tag_masks = []
          reference_masks = []
          if height
            tagged = []
            if member_tags.any?
              stats[:member_tags], tag_masks, tagged = MemberTags.draw(markers.entities, height, data['plan_crop'],
                                                                      member_tags, tag_members, ratio)
            end
            dimension_masks = DrawingDatums.dimension_masks(annotation, ratio)
            grid_masks = []
            if grids.any? && !crop
              bubbles = markers.entities.add_group
              bubbles.name = '通り芯番号'
              grid_masks = PlanLinework.grid_bubbles(bubbles, grids, plan_frame, ratio, dimension_masks + tag_masks, plan_sections)
            end
            stats[:grid_bubbles] = grid_masks.size
            if beam_plan
              if data['beam_labels']
                untagged = labels.reject { |_, _, _, id| tagged.include?(id) }
                stats[:beam_labels] = FramingPlan.draw_labels(markers.entities, untagged, height, ratio,
                                                             masks + dimension_masks + grid_masks + tag_masks)
                stats[:beam_labels_skipped] = untagged.size - stats[:beam_labels]
              end
            else
              room_masks = Rooms.draw_plan(markers.entities, model, data.fetch('level'), height, ratio, hidden)
              stats[:rooms] = room_masks.size
            end
            if plan_partials.any?
              references = markers.entities.add_group
              references.name = '部分平面の参照枠'
              reference_masks = PlanReferences.draw(references, plan_partials, height, ratio,
                                                     dimension_masks + grid_masks + room_masks + tag_masks + masks,
                                                     obstacles: reference_obstacles)
            end
            if plan_sections.any?
              masks_for_marks = dimension_masks + room_masks + tag_masks + reference_masks
              stats[:section_marks] = DrawingDatums.section_marks(markers.entities, plan_sections, plan_frame,
                                                                  height, denominator: ratio, masks: masks_for_marks,
                                                                  grid_masks: grid_masks)
            end
            if overhead.any?
              beam_lines = markers.entities.add_group
              beam_lines.name = '頭上梁（破線）'
              stats[:overhead_beams] = PlanRange.draw_overhead(beam_lines, overhead, height, ratio,
                                                              masks + dimension_masks + grid_masks + room_masks + tag_masks + reference_masks)
            end
          else
            stats[:level_marks], stats[:storey_dimensions] = DrawingDatums.levels(
              markers.entities, API.levels(model), base_box, direction, point, denominator: ratio,
              storey_dimensions: data['storey_dimensions']
            )
            if clearance
              DrawingDatums.clearance_mark(markers.entities, clearance, data.fetch('beam_level'), base_box, direction, point,
                                            denominator: ratio)
            end
            if elevation_levels&.any?
              stats[:elevation_heights] = ElevationDatums.draw(markers.entities, elevation_levels, base_box, direction,
                                                              denominator: ratio)
            end
          end
          markers.entities.each { |entity| entity.layer = model.layers[0] }
          tag_masks + reference_masks
        end
        tags(model).each { |layer| layer.visible = (layer == tag) }
        model.entities.active_section_plane = section
        if point && (!height || data['hatch'])
          stats.merge!(LayerHatches.populate(annotation, point, direction, hidden, denominator: denominator, masks: masks))
        end
        annotation.set_attribute(META, 'stats', JSON.generate(stats))
        annotation.locked = true
        view.camera = camera(view, framing, direction, up, size)
        custom_hatch = stats.fetch(:cut_layers, 0).positive? || stats.fetch(:member_hatch_lines, 0).positive?
        drawing_style(model, data.fetch('kind'), custom_hatch, limited: data.key?('depth'))

        flags = framing_sources.empty? ? FLAGS : FLAGS | PAGE_USE_HIDDEN_GEOMETRY
        page ||= model.pages.add("SBT｜#{title(data)}", flags)
        page.use_hidden_geometry = true if !framing_sources.empty? && !page.use_hidden_geometry?
        page.name = "SBT｜#{title(data)}" if data['kind'] == 'section' && previous && previous['name'] != data['name']
        if previous && %w[plan elevation].include?(data['kind']) && title(previous) != title(data)
          name = "SBT｜#{title(data)}"
          page.name = model.pages[name] ? model.pages.unique_name(name) : name
        end
        page.transition_time = 0
        detail = if beam_plan
                   "梁天端 Z #{format('%g', height)} ±#{format('%g', data.fetch('top_tolerance'))} mm · 梁#{stats[:beam_members]}本"
                 elsif height
                   "床面 +#{data.fetch('cut')} mm で切断"
                 else
                   title(data)
                 end
        detail += " · 奥行き #{format('%g', data['depth'])} mm" if data['depth']
        detail += " · 表示下限 #{format('%+g', data['plan_bottom'])} mm" if data.key?('plan_bottom')
        detail += " · 頭上梁 #{stats.fetch(:overhead_beams, 0)}本" if data.key?('plan_top')
        detail += " · 部分 #{extent.map { |length| format('%g', length.round(1)) }.join(' × ')} mm" if crop
        detail += " · 部分平面の参照 #{plan_partials.size}件" if plan_partials.any?
        broken = stats.fetch(:plan_dimensions, {}).values.count(&:nil?)
        detail += " · 連動寸法の参照切れ #{broken}件" if broken.positive?
        broken_tags = stats.fetch(:member_tags, {}).values.count(&:nil?)
        detail += " · 部材タグの参照切れ #{broken_tags}件" if broken_tags.positive?
        detail = "仮 · #{detail}" if provisional
        page.description = "#{detail} · 1:#{denominator}"
        page.set_attribute(META, 'spec', JSON.generate(data))
        page.set_attribute(META, 'stats', JSON.generate(stats))
        page.set_attribute(META, 'extent_mm', extent)
        page.set_attribute(META, 'paper_scale', denominator)
        page.set_attribute(META, 'sheet_number', number)
        page.set_attribute(META, 'section_references', section_references(sections)) if height
        page.set_attribute(META, 'drawn_section_keys', plan_sections.map { |item| item.fetch('key') }) if height && !beam_plan
        if data['kind'] == 'plan'
          page.set_attribute(META, PlanReferences::SIGNATURE, PlanReferences.signature(plan_partials))
          page.set_attribute(META, PlanReferences::DRAWN_KEYS, plan_partials.map { |item| item.fetch('key') })
        end
        depth_ids = depth_hidden.map(&:persistent_id).to_set
        plan_ids = plan_hidden.map(&:persistent_id)
        if height
          projected_walls = plan_hidden.select { |group| Follow.kind(group) == 'wall' }
          page.set_attribute(META, 'plan_projected_walls', projected_walls.map(&:persistent_id))
        end
        page.set_attribute(META, 'plan_grid_bubbles', stats.fetch(:grid_bubbles)) if height
        page.set_attribute(META, 'auto_hidden', (auto_ids | depth_ids | plan_ids).reject { |id| baseline[id] }.to_a)
        page.update(flags)
        tags(model).each { |layer| page.set_visibility(layer, layer == tag) }
        if height
          model.layers.each do |layer|
            page.set_visibility(layer, true) if layer.get_attribute(API::DICT, GridStyle::KEY)
          end
        end
        (groups + fills + depth_sources + framing_sources).uniq.each do |item|
          id = item.persistent_id
          page.set_drawingelement_visibility(item, !visibility[id] && !depth_ids.include?(id))
        end
        page
      end

      def generate(model, inputs, within_operation: false, provisional: false, update_opening_details: false)
        API.top_level!(model)
        work = inputs.map { |item| spec(model, item) }
        return [] if work.empty?

        existing = specs(model)
        saved = existing.map(&:last).to_h { |item| [item.fetch('key'), item] }
        requested = work.to_h { |item| [item.fetch('key'), item] }
        all = saved.merge(requested)
        named_plans = all.values.filter_map do |item|
          [item['level'], item['plan_name'].downcase] if item['kind'] == 'plan' && item['plan_name']
        end
        raise ArgumentError, '同じ階に同じ名前の平面があります。' unless named_plans.uniq == named_plans

        numbers = assign_sheet_numbers(model, existing, all.keys)
        sections = section_targets(all.values, numbers)
        section_names = sections.map { |item| item.fetch('name') }
        raise ArgumentError, '同じ断面名の図面があります。名前を分けてください。' unless section_names.uniq == section_names

        references = section_references(sections)
        partials = PlanReferences.targets(all.values, numbers)
        uses_depth = all.values.any? { |item| item['depth'] } || saved.values.any? { |item| item['depth'] }
        depth_sources = uses_depth ? SectionDepth.sources(model) : []
        framing_sources = if all.values.any? { |item| item['kind'] == 'framing' }
                            model.entities.grep(Sketchup::Drawingelement).reject do |item|
                              item.is_a?(Sketchup::SectionPlane) || item.layer.get_attribute(META, 'key')
                            end
                          else
                            []
                          end
        related_plans = existing.filter_map do |page, item|
          next unless item['kind'] == 'plan' && !requested.key?(item.fetch('key'))

          item if plan_needs_update?(page, references) || PlanReferences.stale?(page, item, partials)
        end

        view = model.active_view
        current_camera = view.camera
        current_plane = model.entities.active_section_plane
        current_style = model.styles.selected_style
        options = model.rendering_options.keys.to_h { |key| [key, model.rendering_options[key]] }
        previous_tags = tags(model).to_h { |layer| [layer, layer.visible?] }
        previous_objects = (managed_objects(model).flatten + depth_sources + framing_sources).uniq.to_h { |item| [item, item.hidden?] }
        previous_auto = model.pages.selected_page&.get_attribute(META, 'auto_hidden', []) || []
        baseline = previous_objects.to_h { |item, hidden| [item.persistent_id, hidden && !previous_auto.include?(item.persistent_id)] }
        update = lambda do
          begin
            WallHeads.refresh(model) unless within_operation
            Stairs.refresh(model) unless within_operation
            Rooms.refresh(model) unless within_operation
            Openings.update_generic_fills(model) if update_opening_details
            signature = source_signature(model)
            model.set_attribute(META, 'room_schedule_signature', signature) unless within_operation
            last = model.get_attribute(META, 'last_sheet_number', 0)
            model.set_attribute(META, 'last_sheet_number', [last, numbers.values.max].max)
            existing.each do |page, item|
              number = numbers.fetch(item.fetch('key'))
              page.set_attribute(META, 'sheet_number', number) unless page.get_attribute(META, 'sheet_number') == number
              changed = requested[item.fetch('key')]
              if item['kind'] == 'elevation' && changed && title(changed) != title(item)
                page.name = model.pages.unique_name("SBT｜方位更新 #{number}")
              end
            end
            (work + related_plans).map do |item|
              key = item.fetch('key')
              page = build(model, item, baseline, sections, numbers.fetch(key), depth_sources,
                           framing_sources: framing_sources, partials: partials,
                           provisional: provisional && requested.key?(key))
              page.set_attribute(META, 'source_signature', signature)
              page
            end.first(work.size)
          ensure
            view.camera = current_camera
            model.entities.active_section_plane = current_plane
            model.styles.selected_style = current_style if current_style && model.styles.selected_style != current_style
            options.each { |key, value| model.rendering_options[key] = value if model.rendering_options[key] != value }
            tags(model).each { |layer| layer.visible = previous_tags.fetch(layer, false) }
            previous_objects.each { |item, hidden| item.hidden = hidden if item.valid? && item.hidden? != hidden }
          end
        end
        within_operation ? update.call : API.operation(model, '建築図面シーンを作成・更新', &update)
      end

      def open_page(model, page)
        model.pages.selected_page = page
        WorkView.apply(model)
      end

      def show
        @panel ||= Panel.new
        @panel.show
      end

      class Panel
        def show
          if @dialog&.visible?
            @dialog.bring_to_front
            refresh unless @placement
            return
          end
          @dialog = UI::HtmlDialog.new(dialog_title: 'SketchUPbuildingTool 図面・シーン', preferences_key: 'Higeotoko.SbrArchitecture.Drawings',
                                       width: 465, height: 650, min_width: 350, resizable: true,
                                       style: UI::HtmlDialog::STYLE_DIALOG)
          @dialog.set_file(File.join(__dir__, 'drawings.html'))
          @dialog.add_action_callback('ready') { handle { refresh } }
          @dialog.add_action_callback('makeDrawing') { |_, token, input| handle { make(token, JSON.parse(input)) } }
          @dialog.add_action_callback('updateAll') { |_, token, scale| handle { update_all(token, scale) } }
          @dialog.add_action_callback('openDrawing') { |_, token, key| handle { open(token, key) } }
          @dialog.add_action_callback('pickPlanSection') { |_, token| handle { pick_plan_section(token) } }
          @dialog.add_action_callback('pickPlanCrop') { |_, token| handle { pick_plan_crop(token) } }
          @dialog.add_action_callback('pickPlanDimension') { |_, token| handle { pick_plan_dimension(token) } }
          @dialog.add_action_callback('removePlanDimension') { |_, token, key, id| handle { remove_plan_dimension(token, key, id) } }
          @dialog.add_action_callback('pickMemberTag') { |_, token| handle { pick_member_tag(token) } }
          @dialog.add_action_callback('removeMemberTag') { |_, token, key, id| handle { remove_member_tag(token, key, id) } }
          @dialog.add_action_callback('useNativeSection') { |_, token| handle { use_native_section(token) } }
          @dialog.add_action_callback('useRoofEdge') { |_, token, field| handle { use_roof_edge(token, field) } }
          @dialog.add_action_callback('exportLayout') { |_, token, scale, project| handle { export_layout(token, scale, JSON.parse(project)) } }
          @dialog.add_action_callback('savePublication') { |_, token, input| handle { save_publication(token, JSON.parse(input)) } }
          @dialog.add_action_callback('removePublication') { |_, token, id| handle { remove_publication(token, id) } }
          @dialog.add_action_callback('refreshLayoutTables') { |_, token| handle { refresh_layout_tables(token) } }
          @dialog.add_action_callback('exportIfc') { |_, token| handle { export_ifc(token) } }
          @dialog.set_on_closed do
            @dialog = nil
            @placement&.cancel
          end
          @dialog.show
        end

        def handle
          yield
        rescue ArgumentError, KeyError => e
          status(e.message, true)
        rescue StandardError => e
          warn(e.full_message)
          status("図面処理を完了できませんでした。#{e.message}", true)
        end

        def status(message, error = false)
          @dialog&.execute_script("drawingStatus(#{JSON.generate(message)},#{error})")
        end

        def active(token = nil)
          model = Sketchup.active_model
          if token && token != model.object_id.to_s
            refresh
            raise ArgumentError, 'モデルが切り替わりました。もう一度操作してください。'
          end
          model
        end

        def refresh(publication_selection: nil, plan_selection: nil)
          model = active
          specs = Drawings.specs(model)
          pages = specs.map do |page, data|
            [data.fetch('key'), page.name, page.description, Drawings.sheet_label(page.get_attribute(META, 'sheet_number'))]
          end
          sections = specs.map(&:last).select { |data| data['kind'] == 'section' }
          plans = specs.map(&:last).select { |data| %w[plan framing].include?(data['kind']) }
          elevations = specs.map(&:last).select { |data| data['kind'] == 'elevation' }
          current, plan = specs.find { |page, data| page == model.pages.selected_page && %w[plan framing].include?(data['kind']) }
          dimensions = annotation_state(current, plan, PlanDimensions) if plan && plan['kind'] == 'plan'
          member_tags = annotation_state(current, plan, MemberTags) if plan
          state = { token: model.object_id.to_s, levels: API.levels(model).to_a,
                    active: API.active_level(model)&.first, sides: SIDES.transform_values(&:first), pages: pages,
                    north: Drawings.north_side(model), sections: sections, plans: plans, elevations: elevations,
                    plan_dimensions: dimensions, member_tags: member_tags,
                    project_title: model.title, table_update: LayoutScheduleUpdate.available?,
                    publications: PublicationSets.all(model), publication_selection: publication_selection,
                    plan_selection: plan_selection }
          @dialog&.execute_script("receiveDrawings(#{JSON.generate(state)})")
        end

        def annotation_state(page, data, source)
          values = JSON.parse(page.get_attribute(META, 'stats', '{}')).fetch(source::KEY, {})
          { key: data.fetch('key'), name: Drawings.title(data),
            entries: source.entries(page).map { |entry| [entry.fetch('id'), values[entry.fetch('id')]] } }
        end

        def make(token, input)
          model = active(token)
          spec = Drawings.spec(model, input)
          previous = Drawings.specs(model).find { |_, data| data['key'] == spec.fetch('key') }&.last
          input = input.merge('scale' => previous['scale']) if previous && input['scale'].to_s.empty?
          input = input.merge(beam_options(model, input, spec, previous)) if spec['kind'] == 'section'
          page = spec['kind'] == 'elevation' ? Drawings.make_elevation(model, input) : Drawings.generate(model, [input]).first
          Drawings.open_page(model, page)
          saved = JSON.parse(page.get_attribute(META, 'spec'))
          refresh(plan_selection: (saved.fetch('key') if saved['kind'] == 'plan'))
          stats = JSON.parse(page.get_attribute(META, 'stats', '{}'))
          info = stats.key?('wall_edges') ? "（柱断面#{stats['column_cuts']}、開口記号#{stats['opening_marks']}、通り芯#{stats['grids']}）" : ''
          info += " 開き勝手#{stats['door_swings']}件、建具寸法#{stats['opening_dimensions']}本。" if stats.key?('opening_dimensions')
          if stats.key?('beam_members')
            info += if stats['beam_members'].zero?
                      ' 指定範囲に梁がありません。対象の階または梁天端の範囲を調整してください。'
                    else
                      " 梁#{stats['beam_members']}本、柱断面#{stats['column_cuts']}箇所。"
                    end
            if stats.fetch('beam_labels_skipped', 0).positive?
              info += " 重なる断面表記#{stats['beam_labels_skipped']}件を省略しました。"
            end
          end
          info += " 高さ注記#{stats['elevation_heights']}件。" if stats.key?('elevation_heights')
          info += " 層の切断面#{stats['cut_layers']}、ハッチ線#{stats['hatch_lines']}。" if stats.fetch('cut_layers', 0).positive?
          if stats.fetch('skipped_walls', 0).positive?
            info += " 傾いた壁#{stats['skipped_walls']}件はSketchUpの切断表示を使用しています。"
          end
          info += ' 梁下寸法の参照先を確認してください。' if stats['beam_clearance'] == 'unavailable'
          status("#{page.name}を更新しました。#{info}")
        end

        def beam_options(model, input, spec, previous)
          case input['beam_mode']
          when 'use'
            beam = model.selection.first
            unless model.selection.size == 1 && beam.is_a?(Sketchup::Group) && model.entities.include?(beam) &&
                   Follow.kind(beam) == 'beam'
              raise ArgumentError, 'SketchUpで建築パレットの梁を1本選択してください。'
            end

            level = input.fetch('beam_level')
            eye, _, point = Drawings.geometry(model, spec)
            unless DrawingDatums.beam_clearance(beam, API.levels(model)[level], point, eye)
              raise ArgumentError, '断面が選んだ梁を横切り、梁下端が基準レベルより上になるよう設定してください。'
            end

            { 'beam_id' => beam.persistent_id, 'beam_level' => level }
          when 'clear'
            { 'beam_id' => nil }
          else
            previous ? previous.slice('beam_id', 'beam_level') : {}
          end
        end

        def update_all(token, scale)
          model = active(token)
          selected = model.pages.selected_page
          requested = Drawings.scale_value(scale)
          inputs = Drawings.specs(model).map { |_, data| scale.to_s.empty? ? data : data.merge('scale' => requested) }
          pages = Drawings.generate(model, inputs, update_opening_details: true)
          Drawings.open_page(model, selected) if selected && pages.include?(selected)
          refresh
          results = pages.map { |page| JSON.parse(page.get_attribute(META, 'stats', '{}')) }
          skipped = results.count { |stats| stats['beam_clearance'] == 'unavailable' }
          notice = skipped.positive? ? " 梁下寸法#{skipped}件の参照先を確認してください。" : ''
          empty = results.count { |stats| stats['beam_members'] == 0 }
          notice += " 梁のない梁伏図#{empty}枚の天端範囲を確認してください。" if empty.positive?
          broken = results.sum { |stats| stats.fetch(PlanDimensions::KEY, {}).values.count(&:nil?) }
          notice += " 参照切れの連動寸法が#{broken}件あります。" if broken.positive?
          broken_tags = results.sum { |stats| stats.fetch(MemberTags::KEY, {}).values.count(&:nil?) }
          notice += " 参照切れの部材タグが#{broken_tags}件あります。" if broken_tags.positive?
          status("#{pages.size}シーンを更新しました。#{notice}")
        end

        def open(token, key)
          model = active(token)
          page, data = Drawings.specs(model).find { |_, item| item['key'] == key }
          raise ArgumentError, 'シーンがありません。一覧を更新してください。' unless page

          Drawings.open_page(model, page)
          refresh(plan_selection: (key if data['kind'] == 'plan'))
          status("#{page.name}を表示しています。")
        end

        def use_native_section(token)
          data = Drawings.native_section_input(active(token))
          @dialog&.execute_script("receiveSectionPlane(#{JSON.generate(data)})")
          status('断面の位置と向きを読み込みました。名前を付けて作成してください。')
        end

        def pick_plan_section(token)
          model = active(token)
          API.top_level!(model)
          raise ArgumentError, SectionPlacement::TOP_VIEW unless SectionPlacement.top_view?(model.active_view)
          return if @placement

          @placement = SectionPlacement.new(model) do |data|
            @placement = nil
            if data
              @dialog&.execute_script("receiveSectionPlane(#{JSON.generate(data)})")
              status('断面の位置と向きが入りました。「作成・更新して開く」で図面にします。')
              @dialog&.bring_to_front
            else
              status('平面での断面指定を終了しました。')
            end
          end
          model.select_tool(@placement)
        end

        def pick_plan_crop(token)
          model = active(token)
          API.top_level!(model)
          raise ArgumentError, PlanCropPlacement::TOP_VIEW unless SectionPlacement.top_view?(model.active_view)
          return if @placement

          @placement = PlanCropPlacement.new(model) do |crop|
            @placement = nil
            if crop
              @dialog&.execute_script("receivePlanCrop(#{JSON.generate(crop)})")
              status('部分範囲を指定しました。「作成・更新して開く」で保存します。')
              @dialog&.bring_to_front
            else
              status('部分範囲の指定を終了しました。')
            end
          end
          model.select_tool(@placement)
        end

        def annotation_plan(model, kinds, message)
          current = model.pages.selected_page
          result = Drawings.specs(model).find { |page, data| page == current && kinds.include?(data['kind']) }
          result || raise(ArgumentError, message)
        end

        def dimension_plan(model)
          annotation_plan(model, %w[plan], '連動寸法を入れる一般平面シーンを開いてください。')
        end

        def member_tag_plan(model)
          annotation_plan(model, %w[plan framing], '部材タグを入れる一般平面または梁伏図を開いてください。')
        end

        def manually_hidden(groups, page)
          automatic = page.get_attribute(META, 'auto_hidden', []).to_set
          groups.filter_map do |group|
            group.persistent_id if group.hidden? && !automatic.include?(group.persistent_id)
          end.to_set
        end

        def pick_plan_dimension(token)
          model = active(token)
          API.top_level!(model)
          page, data = dimension_plan(model)
          raise ArgumentError, '一般平面を上からの平行投影で開いてください。' unless SectionPlacement.top_view?(model.active_view)
          return if @placement

          cut = Drawings.geometry(model, data).last
          hidden = manually_hidden(model.entities.grep(Sketchup::Group), page)
          anchors = PlanDimensions.references(model, cut, hidden)
          raise ArgumentError, '切断高さに壁仕上面や柱芯がありません。' if anchors.empty?

          @placement = PlanDimensionPlacement.new(model, page, data, cut, anchors) do |entry|
            @placement = nil
            handle do
              if entry
                raise ArgumentError, '寸法を入れるシーンが切り替わりました。' unless model == active && model.pages.selected_page == page

                update_annotations(model, page, data, PlanDimensions, PlanDimensions.entries(page) + [entry], '連動寸法',
                                   saved_id: entry.fetch('id'))
                status('連動寸法を追加しました。')
                @dialog&.bring_to_front
              else
                status('連動寸法の配置を終了しました。')
              end
            end
          end
          model.select_tool(@placement)
        end

        def remove_plan_dimension(token, key, id)
          model = active(token)
          API.top_level!(model)
          page, data = dimension_plan(model)
          raise ArgumentError, '一覧から対象の一般平面を開き直してください。' unless data.fetch('key') == key

          entries = PlanDimensions.entries(page)
          kept = entries.reject { |entry| entry.fetch('id') == id }
          raise ArgumentError, '削除する寸法がありません。' if entries.size == kept.size

          update_annotations(model, page, data, PlanDimensions, kept, '連動寸法')
          status('選んだ連動寸法を削除しました。')
        end

        def pick_member_tag(token)
          model = active(token)
          API.top_level!(model)
          page, data = member_tag_plan(model)
          raise ArgumentError, '対象の平面を上からの平行投影で開いてください。' unless SectionPlacement.top_view?(model.active_view)
          return if @placement

          datum = Drawings.geometry(model, data).last
          groups, = Drawings.managed_objects(model)
          candidates = MemberTags.candidates(model, data, datum, manually_hidden(groups, page), groups)
          raise ArgumentError, 'この図面の表示範囲に柱や梁がありません。' if candidates.empty?

          @placement = MemberTagPlacement.new(model, page, data, datum, candidates) do |entry|
            @placement = nil
            handle do
              if entry
                raise ArgumentError, 'タグを入れるシーンが切り替わりました。' unless model == active && model.pages.selected_page == page

                entries = MemberTags.entries(page)
                index = entries.index { |item| item.fetch('member_id') == entry.fetch('member_id') }
                if index
                  entry['id'] = entries[index].fetch('id')
                  entries[index] = entry
                else
                  entries << entry
                end
                update_annotations(model, page, data, MemberTags, entries, '部材タグ', saved_id: entry.fetch('id'))
                status(index ? '部材タグの位置を更新しました。' : '部材タグを追加しました。')
                @dialog&.bring_to_front
              else
                status('部材タグの配置を終了しました。')
              end
            end
          end
          model.select_tool(@placement)
        end

        def remove_member_tag(token, key, id)
          model = active(token)
          API.top_level!(model)
          page, data = member_tag_plan(model)
          raise ArgumentError, '一覧から対象の図面を開き直してください。' unless data.fetch('key') == key

          entries = MemberTags.entries(page)
          kept = entries.reject { |entry| entry.fetch('id') == id }
          raise ArgumentError, '削除する部材タグがありません。' if entries.size == kept.size

          update_annotations(model, page, data, MemberTags, kept, '部材タグ')
          status('選んだ部材タグを削除しました。')
        end

        def update_annotations(model, page, data, source, entries, label, saved_id: nil)
          API.operation(model, saved_id ? "#{label}を配置" : "#{label}を削除") do
            page.set_attribute(META, source::KEY, JSON.generate(entries))
            Drawings.generate(model, [data], within_operation: true)
            if saved_id
              stats = JSON.parse(page.get_attribute(META, 'stats', '{}'))
              unless stats.dig(source::KEY, saved_id)
                raise ArgumentError, "#{label}を配置できません。参照先と表示範囲を確認してください。"
              end
            end
          end
          Drawings.open_page(model, page)
          refresh(plan_selection: (data.fetch('key') if data['kind'] == 'plan'))
        end

        def use_roof_edge(token, field)
          label = { 'eave' => '軒高', 'ridge' => '棟高' }.fetch(field)
          model = active(token)
          value = ElevationDatums.selected_height(model)
          @dialog&.execute_script("receiveRoofHeight(#{JSON.generate({ field: field, value: value })})")
          message = "#{label}に選択辺のZを入力しました。"
          message += ' グループの編集を終了してから図面を更新してください。' if model.active_path
          status(message)
        end

        def export_layout(token, scale, project)
          model = active(token)
          id = project['publication'].to_s
          publication = PublicationSets.find(model, id) unless id.empty?
          options = publication || project
          tables = options.fetch('tables', [])
          arrangement = options.fetch('arrangement', 'single')
          keys = publication&.fetch('keys')
          allow_missing_sections = project['allow_missing_sections'] == true
          allow_missing_partial_plans = project['allow_missing_partial_plans'] == true
          scenes = LayoutSheets.check_source!(model, keys: keys, tables: tables,
                                             allow_missing_sections: allow_missing_sections,
                                             allow_missing_partial_plans: allow_missing_partial_plans)
          LayoutSheets.project_fields(project, model.title)
          denominator = Drawings.scale_value(scale)
          scenes.each { |scene, _| LayoutSheets.paper_scale(scene, denominator) }
          label = publication&.fetch('name') || '図面'
          label = label.gsub(%r{[<>:"/\\|?*]}, '-')
          file = UI.savepanel('LayOutに図面を配置', '', "#{model.title}-#{label}.layout")
          if file
            count = LayoutSheets.export(model, file, scale: denominator, project: project, tables: tables,
                                       arrangement: arrangement, keys: keys, drawing_index: options['drawing_index'] == true,
                                       allow_missing_sections: allow_missing_sections,
                                       allow_missing_partial_plans: allow_missing_partial_plans)
            status("「#{publication ? publication.fetch('name') : '全図面'}」をLayOut #{count}ページに出力しました。")
          else
            status('保存を取り消しました。')
          end
        end

        def save_publication(token, input)
          model = active(token)
          API.top_level!(model)
          item = PublicationSets.save(model, input)
          refresh(publication_selection: item.fetch('id'))
          status("発行セット「#{item.fetch('name')}」を登録しました。SKPを保存してください。")
        end

        def remove_publication(token, id)
          model = active(token)
          API.top_level!(model)
          item = PublicationSets.remove(model, id)
          refresh(publication_selection: '')
          status("発行セット「#{item.fetch('name')}」を削除しました。SKPを保存してください。")
        end

        def refresh_layout_tables(token)
          model = active(token)
          LayoutScheduleUpdate.check_model!(model)
          source = UI.openpanel("#{File.basename(model.path)}の表で更新するLayOutを選択", File.dirname(model.path), 'LayOutファイル|*.layout||')
          return status('表の更新を取り消しました。') unless source

          name = "#{File.basename(source, File.extname(source))}-表更新.layout"
          destination = UI.savepanel('表を更新したコピーを同じフォルダに保存', File.dirname(source), name)
          return status('表の更新を取り消しました。') unless destination

          result = LayoutScheduleUpdate.save_copy(model, source, destination)
          detail = " 表を#{result[:updated]}枚更新、#{result[:added]}枚追加しました。"
          detail += " 続きが不要になった#{result[:retired]}枚には「続きなし」と表示しました。" if result[:retired].positive?
          detail += ' 旧版のため、LayOutの参照先SKPと開いているSKPが同じか確認してください。' if result[:legacy]
          status("更新したコピーを保存しました。#{detail}")
        end

        def export_ifc(token)
          result = IfcExport.choose_file(active(token))
          if result
            status("IFC4を書き出しました。部材#{result[:elements]}件、開口#{result[:openings]}件、窓#{result[:windows]}件、扉#{result[:doors]}件。")
          else
            status('保存を取り消しました。')
          end
        end
      end
    end
  end
end
