# frozen_string_literal: true

require 'set'

module Higeotoko
  module SbrArchitecture
    module Drawings
      API = SbrArchitecture
      META = 'higeotoko.sbr_architecture.drawing'
      SIDES = {
        'x+' => ['＋X側', [1, 0, 0]], 'x-' => ['−X側', [-1, 0, 0]],
        'y+' => ['＋Y側', [0, 1, 0]], 'y-' => ['−Y側', [0, -1, 0]]
      }.freeze
      FLAGS = PAGE_USE_CAMERA | PAGE_USE_SECTION_PLANES | PAGE_USE_LAYER_VISIBILITY |
              PAGE_USE_HIDDEN_OBJECTS | PAGE_USE_RENDERING_OPTIONS
      VIEW_OPTIONS = {
        'DisplaySectionPlanes' => false, 'DisplaySketchAxes' => false,
        'HideConstructionGeometry' => true, 'SectionCutFilled' => true, 'SectionCutDrawEdges' => true,
        'DisplaySky' => false, 'DisplayGround' => false, 'DrawProfiles' => false
      }.freeze
      module_function

      def specs(model)
        model.pages.filter_map do |page|
          raw = page.get_attribute(META, 'spec')
          [page, JSON.parse(raw)] if raw
        end
      end

      def spec(model, input)
        kind = input.fetch('kind')
        case kind
        when 'plan'
          level = input.fetch('level')
          raise ArgumentError, "作図レベル「#{level}」がありません。" unless API.levels(model).key?(level)

          cut = Layout.mm(input['cut'], '床面からの切断高さ', positive: true)
          { 'key' => "plan:#{level}", 'kind' => kind, 'level' => level, 'cut' => cut }
        when 'elevation'
          side = input.fetch('side')
          SIDES.fetch(side)
          { 'key' => "elevation:#{side}", 'kind' => kind, 'side' => side }
        when 'section'
          name = input['name'].to_s.strip
          raise ArgumentError, '断面に名前を入力してください。' if name.empty? || name.length > 40

          side = input.fetch('side')
          SIDES.fetch(side)
          offset = Layout.mm(input['offset'], '断面の座標')
          { 'key' => "section:#{name}", 'kind' => kind, 'name' => name, 'side' => side, 'offset' => offset }
        else
          raise ArgumentError, '図面の種類を選択してください。'
        end
      end

      def title(data)
        case data.fetch('kind')
        when 'plan' then "平面 #{data.fetch('level')}"
        when 'elevation' then "立面 #{SIDES.fetch(data.fetch('side')).first}"
        when 'section' then "断面 #{data.fetch('name')}"
        end
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

        base = "SBR 図面注記｜#{label}"
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

      def annotate(model, data, point, direction, height, hidden)
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
        stats = height ? PlanLinework.populate(annotation, data.fetch('level'), height, hidden) : {}
        stats.merge!(LayerHatches.populate(annotation, point, direction, hidden))
        annotation.set_attribute(META, 'stats', JSON.generate(stats))
        annotation.locked = true
        [tag, stats]
      end

      def geometry(model, data)
        kind = data.fetch('kind')
        if kind == 'plan'
          level = API.levels(model).fetch(data.fetch('level'))
          height = level + data.fetch('cut')
          return [Z_AXIS, Y_AXIS, API.point(0, 0, height), height]
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
        plane.name = "SBR｜#{title(data)}"
        plane.layer = model.layers[0]
        plane
      end

      def bounds(model, annotation_tag, hidden)
        box = Geom::BoundingBox.new
        model.entities.each do |entity|
          next unless entity.respond_to?(:bounds) && !entity.is_a?(Sketchup::SectionPlane)
          next if entity.respond_to?(:hidden?) &&
                  (hidden.key?(entity.persistent_id) ? hidden.fetch(entity.persistent_id) : entity.hidden?)
          next if entity.respond_to?(:layer) && entity.layer.get_attribute(META, 'key') && entity.layer != annotation_tag
          next if entity.respond_to?(:layer) && !entity.layer.visible? && entity.layer != annotation_tag

          inner = entity.bounds
          box.add(inner.min, inner.max) if inner.valid?
        end
        raise ArgumentError, '図面にする形状がありません。' if !box.valid? || box.diagonal.to_mm < 1

        box
      end

      def camera(view, box, direction, up)
        points = 8.times.map { |index| box.corner(index) }
        horizontal = up.cross(direction)
        x = points.map { |point| (point - ORIGIN).dot(horizontal) }.minmax
        y = points.map { |point| (point - ORIGIN).dot(up) }.minmax
        span = [box.diagonal.to_f, 1000.mm.to_f].max
        eye = box.center + Geom::Vector3d.new(direction.to_a.map { |value| value * span * 2 })
        result = Sketchup::Camera.new(eye, box.center, up, false)
        aspect = view.vpwidth.to_f / [view.vpheight, 1].max
        result.height = [y.last - y.first, (x.last - x.first) / [aspect, 0.1].max, 1000.mm.to_f].max * 1.18
        result
      end

      def managed_objects(model)
        groups, windows = [], []
        model.entities.grep(Sketchup::Group).each do |item|
          groups << item if Follow.kind(item)
          case Follow.kind(item)
          when 'wall'
            windows.concat(item.entities.grep(Sketchup::ComponentInstance).select { |part| part.get_attribute(API::DICT, 'opening_id') })
          end
        end
        [groups, windows]
      end

      def other_storey?(group, level, cut_height)
        assigned = Follow.parameters(group)['level']
        return false unless assigned && assigned != level

        box = group.bounds
        !(box.min.z.to_mm <= cut_height && cut_height < box.max.z.to_mm)
      end

      def drawing_style(model, cuts, layered)
        styles = model.styles
        key = layered ? 'layers' : (cuts ? 'cut' : 'elevation')
        style = styles.find { |item| item.get_attribute(META, 'style') == key }
        if !style && styles.selected_style.respond_to?(:duplicate)
          style = styles.selected_style.duplicate
          style.name = { 'layers' => 'SBR｜図面 層ハッチ', 'cut' => 'SBR｜図面 断面あり', 'elevation' => 'SBR｜図面 立面' }.fetch(key)
          style.set_attribute(META, 'style', key)
        end
        styles.selected_style = style if style
        options = model.rendering_options
        VIEW_OPTIONS.each { |option, value| options[option] = value if options.keys.include?(option) }
        options['DisplaySectionCuts'] = cuts
        options['SectionCutFilled'] = !layered
        options['SectionCutWidth'] = layered ? 1 : 2
        options['BackgroundColor'] = Sketchup::Color.new(255, 255, 255)
        options['SectionDefaultFillColor'] = Sketchup::Color.new(202, 207, 212)
        styles.update_selected_style if style
      end

      def build(model, data, baseline)
        key = data.fetch('key')
        direction, up, point, height = geometry(model, data)
        groups, windows = managed_objects(model)
        automatically_hidden = groups.select do |group|
          Follow.kind(group) == 'grid' || (height && other_storey?(group, data.fetch('level'), height))
        end
        automatically_hidden.concat(windows) if height
        auto_ids = automatically_hidden.map(&:persistent_id).to_set
        visibility = baseline.dup
        auto_ids.each { |id| visibility[id] = true }
        hidden = baseline.select { |_, flag| flag }.keys.to_set
        tag, stats = annotate(model, data, point, direction, height, hidden) if point
        section = section_plane(model, data, point, direction)
        view = model.active_view
        framing = bounds(model, tag, visibility)
        tags(model).each { |layer| layer.visible = (layer == tag) }
        model.entities.active_section_plane = section
        view.camera = camera(view, framing, direction, up)
        drawing_style(model, !section.nil?, stats && stats[:cut_layers].positive?)

        page = specs(model).find { |_, saved| saved['key'] == key }&.first
        page ||= model.pages.add("SBR｜#{title(data)}", FLAGS)
        page.transition_time = 0
        page.description = height ? "床面 +#{data.fetch('cut')} mm で切断" : title(data)
        page.set_attribute(META, 'spec', JSON.generate(data))
        page.set_attribute(META, 'stats', JSON.generate(stats || {}))
        page.set_attribute(META, 'auto_hidden', auto_ids.reject { |id| baseline[id] }.to_a)
        page.update(FLAGS)
        tags(model).each { |layer| page.set_visibility(layer, layer == tag) }
        (groups + windows).each { |item| page.set_drawingelement_visibility(item, !visibility[item.persistent_id]) }
        page
      end

      def generate(model, inputs)
        API.top_level!(model)
        work = inputs.map { |item| spec(model, item) }
        return [] if work.empty?

        view = model.active_view
        current_camera = view.camera
        current_plane = model.entities.active_section_plane
        current_style = model.styles.selected_style
        options = model.rendering_options.keys.to_h { |key| [key, model.rendering_options[key]] }
        previous_tags = tags(model).to_h { |layer| [layer, layer.visible?] }
        previous_objects = managed_objects(model).flatten.to_h { |item| [item, item.hidden?] }
        previous_auto = model.pages.selected_page&.get_attribute(META, 'auto_hidden', []) || []
        baseline = previous_objects.to_h { |item, hidden| [item.persistent_id, hidden && !previous_auto.include?(item.persistent_id)] }
        API.operation(model, '建築図面シーンを作成・更新') do
          begin
            WallHeads.refresh(model)
            work.map { |item| build(model, item, baseline) }
          ensure
            view.camera = current_camera
            model.entities.active_section_plane = current_plane
            model.styles.selected_style = current_style if current_style && model.styles.selected_style != current_style
            options.each { |key, value| model.rendering_options[key] = value if model.rendering_options[key] != value }
            tags(model).each { |layer| layer.visible = previous_tags.fetch(layer, false) }
            previous_objects.each { |item, hidden| item.hidden = hidden if item.valid? && item.hidden? != hidden }
          end
        end
      end

      def open_page(model, page)
        model.pages.selected_page = page
      end

      def show
        @panel ||= Panel.new
        @panel.show
      end

      class Panel
        def show
          if @dialog&.visible?
            @dialog.bring_to_front
            refresh
            return
          end
          @dialog = UI::HtmlDialog.new(dialog_title: 'SketchBRep 図面・シーン', preferences_key: 'Higeotoko.SbrArchitecture.Drawings',
                                       width: 465, height: 650, min_width: 350, resizable: true,
                                       style: UI::HtmlDialog::STYLE_DIALOG)
          @dialog.set_file(File.join(__dir__, 'drawings.html'))
          @dialog.add_action_callback('ready') { handle { refresh } }
          @dialog.add_action_callback('makeDrawing') { |_, token, input| handle { make(token, JSON.parse(input)) } }
          @dialog.add_action_callback('updateAll') { |_, token| handle { update_all(token) } }
          @dialog.add_action_callback('openDrawing') { |_, token, key| handle { open(token, key) } }
          @dialog.add_action_callback('exportLayout') { |_, token| handle { export_layout(token) } }
          @dialog.add_action_callback('exportIfc') { |_, token| handle { export_ifc(token) } }
          @dialog.set_on_closed { @dialog = nil }
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

        def refresh
          model = active
          pages = Drawings.specs(model).map { |page, data| [data.fetch('key'), page.name, page.description] }
          state = { token: model.object_id.to_s, levels: API.levels(model).to_a,
                    active: API.active_level(model)&.first, sides: SIDES.transform_values(&:first), pages: pages }
          @dialog&.execute_script("receiveDrawings(#{JSON.generate(state)})")
        end

        def make(token, input)
          model = active(token)
          page = Drawings.generate(model, [input]).first
          Drawings.open_page(model, page)
          refresh
          stats = JSON.parse(page.get_attribute(META, 'stats', '{}'))
          info = stats.key?('wall_edges') ? "（壁線#{stats['wall_edges']}、開口記号#{stats['opening_marks']}、通り芯#{stats['grids']}）" : ''
          info += " 層の切断面#{stats['cut_layers']}、ハッチ線#{stats['hatch_lines']}。" if stats.fetch('cut_layers', 0).positive?
          if stats.fetch('skipped_walls', 0).positive?
            info += " 傾いた壁#{stats['skipped_walls']}件はSketchUpの切断表示を使用しています。"
          end
          status("#{page.name}を更新しました。#{info}")
        end

        def update_all(token)
          model = active(token)
          selected_key = model.pages.selected_page&.get_attribute(META, 'spec')
          pages = Drawings.generate(model, Drawings.specs(model).map(&:last))
          if selected_key
            page = pages.find { |entry| entry.get_attribute(META, 'spec') == selected_key }
            Drawings.open_page(model, page) if page
          end
          refresh
          status("#{pages.size}シーンを更新しました。")
        end

        def open(token, key)
          model = active(token)
          page = Drawings.specs(model).find { |_, item| item['key'] == key }&.first
          raise ArgumentError, 'シーンがありません。一覧を更新してください。' unless page

          Drawings.open_page(model, page)
          status("#{page.name}を表示しています。")
        end

        def export_layout(token)
          model = active(token)
          LayoutSheets.check_source!(model)
          file = UI.savepanel('LayOutに図面を配置', '', "#{model.title}-図面.layout")
          if file
            count = LayoutSheets.export(model, file)
            status("LayOutに#{count}ページを配置しました。")
          else
            status('保存を取り消しました。')
          end
        end

        def export_ifc(token)
          result = IfcExport.choose_file(active(token))
          if result
            status("IFC4を書き出しました。部材#{result[:elements]}件、開口#{result[:openings]}件、サッシ#{result[:windows]}件。")
          else
            status('保存を取り消しました。')
          end
        end
      end
    end
  end
end
