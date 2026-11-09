# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Sashes
      API = SbrArchitecture
      module_function

      def available?
        defined?(::LixilSashGenerator::ProductCatalog) &&
          ::LixilSashGenerator.respond_to?(:populate_product) &&
          ::LixilSashGenerator.respond_to?(:stamp_product)
      end

      def options
        return [] unless available?

        ::LixilSashGenerator::ProductCatalog.entries.filter_map do |entry|
          [entry.fetch('id'), entry.fetch('label')] if entry.dig('validation', 'passed') == true
        end
      end

      def config(values, previous)
        id = values['product'].to_s
        return nil if id.empty?

        unless previous&.fetch('product_id', nil) == id || options.any? { |product, _| product == id }
          raise ArgumentError, '出力可能なLIXIL登録製品を選択してください。'
        end
        side = values.fetch('side')
        raise ArgumentError, '外側は壁芯の左側か右側を指定してください。' unless %w[left right].include?(side)

        inset = Layout.mm(values['inset'], '外側からの引込み')
        raise ArgumentError, '引込みは0 mm以上にしてください。' if inset.negative?

        { 'product_id' => id, 'side' => side, 'inset' => inset }
      end

      def capture(group)
        group.entities.grep(Sketchup::ComponentInstance).filter_map do |instance|
          id = instance.get_attribute(API::DICT, 'opening_id')
          next unless id

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
        config = opening.fetch('sash')
        inset = config.fetch('inset')
        raise ArgumentError, '引込みは壁厚より小さくしてください。' unless inset < params.fetch('thickness')

        origin, axis = Openings.segment(params.fetch('points'), opening.fetch('segment'))
        left_axis = [-axis[1], axis[0]]
        right_side = config.fetch('side') == 'right'
        edge = Openings.projection(profile.fetch(right_side ? 1 : 0), origin, left_axis)
        lateral = edge + (right_side ? inset : -inset)
        x = opening.fetch('offset')
        anchor = API.point(origin[0] + x * axis[0] + lateral * left_axis[0],
                           origin[1] + x * axis[1] + lateral * left_axis[1], opening.fetch('sill'))
        direction = right_side ? 1 : -1
        Geom::Transformation.axes(anchor, Geom::Vector3d.new(axis[0] * direction, axis[1] * direction, 0),
                                  Geom::Vector3d.new(left_axis[0] * direction, left_axis[1] * direction, 0), Z_AXIS)
      end

      def write(group, params, profiles, stored)
        params.fetch('openings', []).each do |opening|
          next unless opening['sash']

          tr = placement(params, profiles.fetch(opening.fetch('segment')), opening)
          data = definition_for(group.model, opening, stored[opening.fetch('id')])
          instance = group.entities.add_instance(data.fetch(:definition), tr)
          if data[:attributes]
            data[:attributes].each { |key, value| instance.set_attribute('lixilsashgenerator', key, value) }
            instance.name = data[:name]
          else
            ::LixilSashGenerator.stamp_product(instance, data.fetch(:parameters))
          end
          instance.layer = group.model.layers[0]
          instance.set_attribute(API::DICT, 'opening_id', opening.fetch('id'))
        end
      end
    end
  end
end
