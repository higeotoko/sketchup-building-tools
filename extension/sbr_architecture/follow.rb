# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Follow
      API = SbrArchitecture
      GRID_KINDS = %w[column beam wall].freeze
      KINDS = (GRID_KINDS + %w[slab roof]).freeze
      NONE = '関連付けなし'
      module_function

      def data(group)
        JSON.parse(group.get_attribute(API::DICT, 'follow', '{}'))
      end

      def kind(group)
        group.get_attribute(API::DICT, 'kind')
      end

      def parameters(group)
        JSON.parse(group.get_attribute(API::DICT, 'parameters'))
      end

      def anchors(type, params)
        case type
        when 'column' then [[0, 0]]
        when 'beam' then [[0, 0], params.fetch('end')]
        when 'wall' then params.fetch('points')
        end
      end

      def axes(params)
        %w[x y].map do |axis|
          params.fetch("#{axis}_names").zip(Layout.stations(params.fetch("#{axis}_spans"))).to_h
        end
      end

      def nearest(grid, group, params)
        current = API.placement_for(group, kind(group), params)
        inverse = grid.transformation.inverse
        grid_axes = axes(parameters(grid))
        anchors(kind(group), params).map do |coordinates|
          local = API.point(*coordinates).transform(current).transform(inverse)
          pair = grid_axes.zip([local.x.to_mm, local.y.to_mm]).map do |stations, value|
            name, position = stations.min_by { |_, offset| (offset - value).abs }
            raise ArgumentError, '各芯点が通り芯の交点から10 mm以内に来るよう配置してください。' if (position - value).abs > 10

            name
          end
          pair
        end
      end

      def bind(group, grid, level)
        type = kind(group)
        raise ArgumentError, '柱・梁・壁・床・屋根を1つ選択してください。' unless KINDS.include?(type)
        raise ArgumentError, '部材のロックを解除してください。' if group.locked?

        model = group.model
        API.top_level!(model)
        params = parameters(group)
        links = {}
        if grid
          raise ArgumentError, 'この部材は階に関連付けできます。' unless GRID_KINDS.include?(type)
          raise ArgumentError, '同じモデルの通り芯を選択してください。' unless kind(grid) == 'grid' && grid.model == model

          links['grid'] = grid.persistent_id.to_s
          links['anchors'] = nearest(grid, group, params)
        end
        if level
          raise ArgumentError, 'モデルに登録済みの階を選択してください。' unless API.levels(model).key?(level)

          links['level'] = level
        end
        API.operation(model, '通り芯・階との関連付け') do
          group.set_attribute(API::DICT, 'follow', JSON.generate(links))
          API.store_params(group, type, params.merge('level' => level)) if level
        end
        links
      end

      def dialog(group)
        API.report_errors do
          model = group.model
          API.top_level!(model)
          levels = [NONE, *API.levels(model).keys]
          links = data(group)
          prompts = ['追従する階']
          defaults = [links['level'] || NONE]
          lists = [levels.join('|')]
          grid_options = { NONE => nil }
          if GRID_KINDS.include?(kind(group))
            model.entities.grep(Sketchup::Group).each do |grid|
              next unless kind(grid) == 'grid'

              grid_options["#{grid.name.tr('|', '｜')} ##{grid.persistent_id}"] = grid
            end
            current = grid_options.find { |_, grid| grid && grid.persistent_id.to_s == links['grid'] }&.first || NONE
            prompts.unshift('通り芯（芯点は交点から10 mm以内）')
            defaults.unshift(current)
            lists.unshift(grid_options.keys.join('|'))
          end
          title = prompts.one? ? "#{API.object_name(kind(group))}を階に関連付け" : '通り芯・階に関連付け'
          values = UI.inputbox(prompts, defaults, lists, title)
          next unless values

          grid = grid_options.fetch(values.first) if values.size == 2
          level = values.last
          bind(group, grid, level == NONE ? nil : level)
        end
      end

      def dependents(model)
        model.entities.grep(Sketchup::Group).filter_map do |item|
          next unless KINDS.include?(kind(item))

          links = data(item)
          [item, links] unless links.empty?
        end
      end

      def grid_points(names, stations, transform)
        names.map do |x, y|
          px, py = stations[0][x], stations[1][y]
          raise ArgumentError, "関連付け済みの通り #{x}/#{y} がありません。名前を戻すか関連付けを解除してください。" if !px || !py

          API.point(px, py).transform(transform)
        end
      end

      def update_grid(grid, previous, params, new_transform)
        old_axes = axes(previous)
        new_axes = axes(params)
        dependents(grid.model).each do |item, links|
          next unless links['grid'] == grid.persistent_id.to_s

          names = links.fetch('anchors')
          old_points = grid_points(names, old_axes, grid.transformation)
          new_points = grid_points(names, new_axes, new_transform)
          offsets = new_points.zip(old_points).map { |a, b| a - b }
          next if offsets.all? { |offset| offset.length.to_mm < 0.0001 }
          raise ArgumentError, "関連部材「#{item.name}」のロックを解除してください。" if item.locked?

          update_geometry(item, offsets)
        end
      end

      def update_geometry(item, offsets)
        type = kind(item)
        old = parameters(item)
        points = anchors(type, old)
        unless points.size == offsets.size
          raise ArgumentError, "「#{item.name}」の芯点が変わりました。通り芯に関連付け直してください。"
        end
        displacement = Geom::Transformation.translation(offsets.first)
        if offsets.all? { |offset| (offset - offsets.first).length.to_mm < 0.0001 }
          item.transformation = displacement * item.transformation
          return
        end

        old_transform = API.placement_for(item, type, old)
        placement = displacement * old_transform
        inverse = placement.inverse
        local = points.zip(offsets).map do |point, offset|
          world = API.point(*point).transform(old_transform) + offset
          result = world.transform(inverse)
          raise ArgumentError, '移動先は部材の作図面上にある必要があります。' if result.z.to_mm.abs > 0.001

          [result.x.to_mm.round(6), result.y.to_mm.round(6)]
        end
        if type == 'wall' && points.first == points.last
          local[-1] = local.first
        end
        replacement = type == 'wall' ? old.merge('points' => local) : old.merge('end' => local.fetch(1))
        API.rebuild(item, type, replacement, old, placement)
      end

      def set_levels(model, pairs)
        previous = API.levels(model)
        updated = pairs.to_h
        API.operation(model, '作図レベルを更新') do
          dependents(model).each do |item, links|
            level = links['level']
            next unless level
            raise ArgumentError, "「#{item.name}」が階 #{level} を参照しています。階名を戻すか関連付けを解除してください。" unless updated.key?(level) && previous.key?(level)

            delta = updated.fetch(level) - previous.fetch(level)
            next if delta.zero?
            raise ArgumentError, "関連部材「#{item.name}」のロックを解除してください。" if item.locked?

            item.transformation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, delta.mm)) * item.transformation
          end
          WallHeads.refresh(model)
          model.set_attribute(API::DICT, 'levels', pairs.map { |pair| pair.join('=') }.join(','))
          Stairs.refresh(model)
        end
      end
    end
  end
end
