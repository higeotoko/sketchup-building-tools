# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module GridStyle
      NAME = 'SBR｜通り芯線'
      KEY = 'grid_axis_style'
      VIEW_OPTIONS = { 'EdgeColorMode' => 0, 'DisplayColorByLayer' => false, 'EdgeType' => 0,
                       'DrawSilhouettes' => false, 'DrawProfilesOnly' => false, 'DrawDepthQue' => false }.freeze
      module_function

      def pattern_spans(length)
        spans = []
        start = 0.0
        while start < length
          [[0, 410], [510, 560]].each do |first, last|
            finish = [start + last, length].min
            spans << [start + first, finish] if finish - start - first >= 1
          end
          start += 660
        end
        spans
      end

      def add_axis(entities, a, b)
        length = a.distance(b).to_mm
        pattern_spans(length).map do |first, last|
          points = [first, last].map { |value| Geom.linear_combination(1 - value / length, a, value / length, b) }
          entities.add_line(*points)
        end.compact
      end

      def show_in_view(model)
        options = model.rendering_options
        VIEW_OPTIONS.each { |key, value| options[key] = value if options.keys.include?(key) }
      end

      def apply(group, edges = group.entities.grep(Sketchup::Edge))
        model = group.model
        tag = model.layers.find { |item| item.get_attribute(SbrArchitecture::DICT, KEY) == 'patterned' }
        unless tag
          name = NAME
          suffix = 1
          while model.layers[name]
            suffix += 1
            name = "#{NAME} #{suffix}"
          end
          tag = model.layers.add(name)
          tag.set_attribute(SbrArchitecture::DICT, KEY, 'patterned')
        end
        tag.line_style = nil if tag.line_style
        material = model.materials[NAME] || model.materials.add(NAME)
        red = Sketchup::Color.new(192, 28, 36)
        material.color = red unless material.color == red
        edges.each do |edge|
          edge.layer = tag unless edge.layer == tag
          edge.material = material unless edge.material == material
        end
        tag
      end

      def legacy_axes(grid)
        api = SbrArchitecture
        params = Follow.parameters(grid)
        xs, ys = %w[x_spans y_spans].map { |key| Layout.stations(params.fetch(key)) }
        axis_points = ->(stations) { [-360.0, *stations, stations.last + 360.0].map { |mm| mm.round(4) } }
        x_endpoints, y_endpoints = [axis_points.call(xs), axis_points.call(ys)]
        grid.entities.grep(Sketchup::Edge).select do |edge|
          style = edge.layer.get_attribute(api::DICT, KEY)
          next true if style == true
          next false if style || edge.layer != grid.model.layers[0]

          a, b = edge.vertices.map { |vertex| vertex.position.to_a.map { |value| value.to_mm.round(4) } }
          x1, y1, z1 = a
          x2, y2, z2 = b
          z1.zero? && z2.zero? &&
            ((x1 == x2 && x_endpoints[1...-1].include?(x1) && [y1, y2].all? { |y| y_endpoints.include?(y) }) ||
             (y1 == y2 && y_endpoints[1...-1].include?(y1) && [x1, x2].all? { |x| x_endpoints.include?(x) }))
        end
      end

      def repair(model)
        api = SbrArchitecture
        api.top_level!(model)
        api.operation(model, '通り芯を赤い一点鎖線に整える') do
          grids = model.entities.grep(Sketchup::Group).select { |group| Follow.kind(group) == 'grid' && !group.locked? }
          raise ArgumentError, '編集できる通り芯がありません。建築パレットで作図するか、通り芯のロックを解除してください。' if grids.empty?

          grids.each do |grid|
            next if legacy_axes(grid).empty?

            grid.make_unique
            edges = legacy_axes(grid)
            points = edges.map { |edge| [edge.start.position, edge.end.position] }
            grid.entities.erase_entities(edges)
            apply(grid, points.flat_map { |a, b| add_axis(grid.entities, a, b) })
          end
          plans = Drawings.specs(model).map(&:last).select { |data| data['kind'] == 'plan' }
          Drawings.seed_from_grid(model)
          Drawings.generate(model, plans, within_operation: true)
          show_in_view(model)
          WorkView.without_override(model) { model.styles.update_selected_style if model.styles.selected_style }
          grids.size
        end
      end
    end
  end
end
