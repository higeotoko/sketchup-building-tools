# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module ColumnCenters
      API = SbrArchitecture
      module_function

      def add(group, params)
        steel = params['system'] == 'steel'
        entities = group.entities
        existing = entities.grep(Sketchup::ConstructionPoint)
        points = [0.0, params.fetch('height') / 2.0, params.fetch('height')].map do |z|
          position = steel ? API.point(z, 0) : API.point(0, 0, z)
          point = existing.find { |guide| guide.position.distance(position).to_mm < 0.001 }
          point ||= entities.add_cpoint(position)
          point.set_attribute(API::DICT, 'column_center', true)
          point.set_attribute(Catalog::STEEL::SNAP_DICTIONARY, 'owned', true) if steel
          point.layer = group.model.layers[0]
          point
        end
        raise ArgumentError, '柱芯点を追加できませんでした。' unless points.size == 3

        if steel
          group.set_attribute(Catalog::STEEL::DICTIONARY, 'geometry_signature', Catalog::STEEL::MemberReader.signature(group))
        end
      end

      def pick(view, x, y)
        return if view.model.rendering_options['HideConstructionGeometry']

        guide = Catalog::STEEL::SnapPoints.pick(view, x, y,
                                                group_filter: ->(g) { g.get_attribute(API::DICT, 'kind') == 'column' },
                                                point_filter: ->(p) { p.get_attribute(API::DICT, 'column_center', false) })
        return guide if guide

        # Looking down a hollow section, the cursor can sit inside its void.
        # There may be no picked face even though its center guide is on screen.
        eye = view.camera.eye
        direction = view.camera.direction
        candidates = view.model.entities.grep(Sketchup::Group).flat_map do |group|
          next [] unless group.get_attribute(API::DICT, 'kind') == 'column' &&
                         group.get_attribute(API::DICT, 'structural_system') == 'steel' &&
                         !group.hidden? && group.layer.visible?

          group.entities.grep(Sketchup::ConstructionPoint).filter_map do |point|
            next unless point.get_attribute(API::DICT, 'column_center', false) && !point.hidden? && point.layer.visible?

            world = point.position.transform(group.transformation)
            delta = world - eye
            next unless delta.dot(direction).positive?

            screen = view.screen_coords(world)
            distance = Math.hypot(screen.x - x, screen.y - y)
            [distance, delta.length.to_f, world] if distance <= 10
          end
        end
        candidates.min_by { |distance, depth, _| [distance, depth] }&.last
      end

      def update(group)
        API.report_errors do
          API.top_level!(group.model)
          raise ArgumentError, 'ロックを解除してから柱芯点を追加してください。' if group.locked?

          params = JSON.parse(group.get_attribute(API::DICT, 'parameters'))
          if params['system'] == 'steel'
            Catalog::STEEL::MemberReader.read([group])
          end
          API.operation(group.model, '柱芯点を追加') do
            group.make_unique
            add(group, params)
          end
        end
      end
    end
  end
end
