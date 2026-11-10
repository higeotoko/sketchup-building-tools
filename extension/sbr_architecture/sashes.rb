# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Sashes
      API = SbrArchitecture
      DETAIL_VERSION = 2
      SLIDING_DEPTH = 64.0
      SLIDING_TYPES = %w[sliding single_slide].freeze
      module_function

      def available?
        defined?(::LixilSashGenerator::ProductCatalog) &&
          ::LixilSashGenerator.respond_to?(:populate_product) &&
          ::LixilSashGenerator.respond_to?(:stamp_product)
      end

      def options
        return [] unless available?

        ::LixilSashGenerator::ProductCatalog.entries.filter_map do |entry|
          next unless entry.dig('validation', 'passed') == true

          id = entry.fetch('id')
          capability = ::LixilSashGenerator::ProductCatalog.fetch(id).dig('capabilities', 'type')
          type = { 'fixed' => 'fixed', 'double_sliding' => 'sliding' }[capability]
          [id, entry.fetch('label'), type]
        rescue ArgumentError, JSON::ParserError
          nil
        end
      end

      def config(values, previous)
        id = values['product'].to_s
        return nil if id.empty?

        stored = previous&.fetch('product_id', nil) == id
        product = options.find { |entry| entry.first == id } unless stored
        unless stored || product
          raise ArgumentError, '出力可能なLIXIL登録製品を選択してください。'
        end
        if product&.last && values['window_type'] && product.last != values['window_type']
          raise ArgumentError, '窓の形式と一致するLIXIL製品を選択してください。'
        end
        return stored ? previous : { 'product_id' => id } unless values.key?('side')

        side = values.fetch('side')
        raise ArgumentError, '外側は壁芯の左側か右側を指定してください。' unless %w[left right].include?(side)

        inset = Layout.mm(values['inset'], '外側からの引込み')
        raise ArgumentError, '引込みは0 mm以上にしてください。' if inset.negative?

        { 'product_id' => id, 'side' => side, 'inset' => inset }
      end

      def capture(group)
        group.entities.grep(Sketchup::ComponentInstance).filter_map do |instance|
          id = instance.get_attribute(API::DICT, 'opening_id')
          next unless id && instance.get_attribute('lixilsashgenerator', 'parameters')

          [id, { definition: instance.definition, parameters: JSON.parse(instance.get_attribute('lixilsashgenerator', 'parameters')),
                 product_hash: instance.get_attribute('lixilsashgenerator', 'product_definition_sha256'),
                 name: instance.name, attributes: instance.attribute_dictionary('lixilsashgenerator', false).to_h }]
        end.to_h
      end

      def definition_for(model, opening, stored)
        id = opening.fetch('sash').fetch('product_id')
        dimensions = opening.values_at('width', 'height')
        parameters = stored && stored[:parameters]
        if parameters && parameters['product_id'] == id && parameters.values_at('width', 'height') == dimensions
          return stored
        end
        raise ArgumentError, 'サッシの新規配置・寸法変更にはLIXILサッシジェネレーターが必要です。' unless available?

        lixil = ::LixilSashGenerator
        snapshot = if parameters && parameters['product_id'] == id
                     raw = stored.fetch(:definition).get_attribute(lixil::DICT, 'product_definition')
                     unless raw && Digest::SHA256.hexdigest(raw) == stored[:product_hash]
                       raise ArgumentError, '保存済みのLIXIL製品定義を照合できません。'
                     end
                     JSON.parse(raw)
                   else
                     lixil::ProductCatalog.fetch(id)
                   end
        input = { 'product_id' => id, 'width' => dimensions[0], 'height' => dimensions[1], 'rotation' => 0 }
        input['finish'] = parameters['finish'] if parameters && parameters['product_id'] == id
        normalized = lixil::ProductEngine.validate(input, snapshot)
        definition = model.definitions.add("LSG_#{id}")
        lixil.populate_product(definition, normalized, model, snapshot)
        { definition: definition, parameters: normalized }
      end

      def placement(params, profile, opening)
        points = params.fetch('points')
        origin, axis = Openings.segment(points, opening.fetch('segment'))
        left_axis = [-axis[1], axis[0]]
        left, right = profile.first(2).map { |vertex| Openings.projection(vertex, origin, left_axis) }
        lateral, outward = Openings.window_anchor(opening, left, right, points, outside: Layout.wall_outside(params))
        x = opening.fetch('offset')
        anchor = API.point(origin[0] + x * axis[0] + lateral * left_axis[0],
                           origin[1] + x * axis[1] + lateral * left_axis[1], opening.fetch('sill'))
        direction = -outward
        Geom::Transformation.axes(anchor, Geom::Vector3d.new(axis[0] * direction, axis[1] * direction, 0),
                                  Geom::Vector3d.new(left_axis[0] * direction, left_axis[1] * direction, 0), Z_AXIS)
      end

      def generic_definition(model, opening)
        type = Openings.window_type(opening)
        width, height = opening.values_at('width', 'height')
        sliding = SLIDING_TYPES.include?(type)
        signature = JSON.generate(sliding ? [DETAIL_VERSION, type, width, height] : [type, width, height])
        existing = model.definitions.find { |item| item.get_attribute(API::DICT, 'window_signature') == signature }
        return existing if existing

        definition = model.definitions.add("SBR 窓 #{Openings::WINDOW_TYPES.fetch(type)}")
        definition.set_attribute(API::DICT, 'window_signature', signature)
        glass = model.materials['SBR 窓ガラス'] || model.materials.add('SBR 窓ガラス')
        glass.color = Sketchup::Color.new(137, 191, 208)
        glass.alpha = 0.35
        trim = frame_width(width, height)
        depth = sliding ? SLIDING_DEPTH : 40.0
        left, right = [-width / 2.0, width / 2.0]
        ring(definition.entities, [left, 0, right, height], 0, depth, trim)
        if sliding
          seat = trim + sliding_clearance(width, height)
          sliding_parts(width, height).each do |(x1, x2), (front, back), stile|
            bounds = [x1 - width / 2.0, seat, x2 - width / 2.0, height - seat]
            ring(definition.entities, bounds, front, back, stile)
            glaze(definition.entities, bounds, (front + back) / 2.0, stile, glass)
          end
          return definition
        end
        inner = [[left + trim, trim], [right - trim, trim], [right - trim, height - trim], [left + trim, height - trim]]
        panes = case type
                when 'double_hung'
                  [[inner[0], [right - trim, height / 2.0], depth * 0.35],
                   [[left + trim, height / 2.0], inner[2], depth * 0.65]]
                when 'double_casement'
                  [[inner[0], [-trim / 2, height - trim], depth / 2.0],
                   [[trim / 2, trim], inner[2], depth / 2.0]]
                else
                  [[inner[0], inner[2], depth / 2.0]]
                end
        panes.each do |(x1, z1), (x2, z2), y|
          glaze(definition.entities, [x1, z1, x2, z2], y, 0, glass)
        end
        definition
      end

      def frame_width(width, height)
        [32.0, width * 0.16, height * 0.16].min
      end

      def sliding_parts(width, height)
        trim = frame_width(width, height)
        seat = trim + sliding_clearance(width, height)
        overlap = [14.0, width * 0.08].min
        middle = width / 2.0
        # Two parallel sash sections meet around the centre of the opening.
        spans = [[seat, middle + overlap], [middle - overlap, width - seat]]
        spans.zip([[8.0, 28.0], [36.0, 56.0]]).map do |(a, b), track|
          stile = [25.0, (b - a) * 0.15, (height - seat * 2) * 0.15].min
          [[a, b], track, stile]
        end
      end

      def sliding_clearance(width, height)
        [1.5, width * 0.015, height * 0.015].min
      end

      def outline(bounds, inset)
        x1, z1, x2, z2 = bounds
        [[x1 + inset, z1 + inset], [x2 - inset, z1 + inset],
         [x2 - inset, z2 - inset], [x1 + inset, z2 - inset]]
      end

      def section_points(outline, y)
        outline.map { |x, z| API.point(x, y, z) }
      end

      def ring(entities, bounds, front, back, trim)
        outer = outline(bounds, 0)
        inner = outline(bounds, trim).reverse
        entities.build do |builder|
          builder.add_face(section_points(outer, front), holes: [section_points(inner, front)])
          builder.add_face(section_points(outer.reverse, back), holes: [section_points(inner.reverse, back)])
          [outer, inner].each do |loop|
            loop.zip(loop.rotate).each do |a, b|
              builder.add_face(section_points([b, a], front) + section_points([a, b], back))
            end
          end
        end
      end

      def glaze(entities, bounds, y, trim, glass)
        face = entities.add_face(section_points(outline(bounds, trim), y))
        raise ArgumentError, 'サッシのガラス面を作成できません。開口寸法を確認してください。' unless face

        face.material = face.back_material = glass
      end

      def write(group, params, profiles, stored)
        params.fetch('openings', []).each do |opening|
          next unless opening['sash'] || opening['window_type']

          tr = placement(params, profiles.fetch(opening.fetch('segment')), opening)
          data = if opening['sash']
                   definition_for(group.model, opening, stored[opening.fetch('id')])
                 else
                   { definition: generic_definition(group.model, opening) }
                 end
          instance = group.entities.add_instance(data.fetch(:definition), tr)
          if data[:attributes]
            data[:attributes].each { |key, value| instance.set_attribute('lixilsashgenerator', key, value) }
            instance.name = data[:name]
          elsif opening['sash']
            ::LixilSashGenerator.stamp_product(instance, data.fetch(:parameters))
          end
          instance.layer = group.model.layers[0]
          instance.set_attribute(API::DICT, 'opening_id', opening.fetch('id'))
        end
      end
    end
  end
end
