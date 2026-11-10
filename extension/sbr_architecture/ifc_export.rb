# frozen_string_literal: true

require 'tmpdir'
require_relative 'ifc_step'

module Higeotoko
  module SbrArchitecture
    module IfcExport
      API = SbrArchitecture
      SCHEMA = 'IFC 4'
      CLASSES = {
        'wall' => ['IfcWall', 'Qto_WallBaseQuantities'],
        'slab' => ['IfcSlab', 'Qto_SlabBaseQuantities', '.FLOOR.'],
        'column' => ['IfcColumn', 'Qto_ColumnBaseQuantities', '.COLUMN.'],
        'beam' => ['IfcBeam', 'Qto_BeamBaseQuantities', '.BEAM.'],
        'sill' => ['IfcBeam', 'Qto_BeamBaseQuantities', '.BEAM.'],
        'strip_foundation' => ['IfcFooting', 'Qto_FootingBaseQuantities', '.STRIP_FOOTING.'],
        'pad_foundation' => ['IfcFooting', 'Qto_FootingBaseQuantities', '.PAD_FOOTING.']
      }.freeze
      UNASSIGNED = '階未指定'
      module_function

      def sources(model)
        model.entities.grep(Sketchup::Group).select { |group| CLASSES.key?(Follow.kind(group)) }
      end

      def schema!(model)
        return if model.classifications[SCHEMA]

        path = Sketchup.find_support_file('IFC4.skc', 'Classifications')
        path = Sketchup.get_resource_path('../ShippedClassifications/IFC4.skc') unless path && File.file?(path)
        raise ArgumentError, 'モデルにIFC 4分類を読み込んでください。' unless path && File.file?(path)

        model.classifications.load_schema(path)
        raise ArgumentError, 'IFC 4分類を読み込めません。' unless model.classifications[SCHEMA]
      end

      def classify(instance, token, type)
        instance.layer = instance.model.layers[0]
        instance.hidden = false
        instance.name = token
        definition = instance.definition
        definition.name = token
        previous = definition.get_attribute('AppliedSchemaTypes', SCHEMA)
        if previous && !definition.remove_classification(SCHEMA, previous)
          raise ArgumentError, "一時部材のIFC分類「#{previous}」を解除できません。"
        end
        unless definition.add_classification(SCHEMA, type)
          raise ArgumentError, "#{type}のIFC分類を設定できません。"
        end
      end

      def component(storey, source, transformation, token, type)
        copy = storey.entities.add_instance(source.definition, storey.transformation.inverse * transformation)
        copy.make_unique
        classify(copy, token, type)
        copy
      end

      def elevation_for(params, levels)
        level = params['level']
        return [UNASSIGNED, nil] unless level && levels.key?(level)

        [level, levels.fetch(level)]
      end

      def properties(group, params, level)
        result = { 'SketchUpPersistentId' => group.persistent_id.to_s, 'StoreyName' => level,
                   'BimRole' => Follow.kind(group) }
        result['StructuralSystem'] = Catalog::SYSTEMS.fetch(params['system'], params['system']) if params['system']
        result['SectionId'] = params['section_id'] if params['section_id']
        result['MemberRole'] = params['role'] if params['role']
        { 'thickness' => 'NominalThickness', 'width' => 'NominalWidth',
          'depth' => 'NominalDepth', 'height' => 'NominalHeight' }.each do |key, label|
          result[label] = params.fetch(key) / 1000.0 if params.key?(key)
        end
        if params.dig('head', 'outside_height')
          result['InteriorStopHeight'] = result.fetch('NominalHeight')
          result['NominalHeight'] = WallHeads.overall_height(params) / 1000.0
        end
        layer_rows = Schedule.composition_rows(group, Follow.kind(group), level, group.persistent_id.to_s)
        if layer_rows.any?
          info = layer_rows.map { |row| { name: row[2], thickness_mm: row[4], net_volume_m3: row[7] } }
          result['CompositionLayers'] = JSON.generate(info)
        end
        result
      end

      def opening_points(group, params, opening, profile)
        projections, at = PlanLinework.basis(params, profile, opening.fetch('segment'))
        left, right = projections[0][1], projections[1][1]
        x1, x2, z1, z2 = Openings.position(opening)
        plan = [[x1, right], [x2, right], [x2, left], [x1, left]]
        [z1, z2].flat_map do |z|
          plan.map { |x, y| at.call(x, y, z).transform(group.transformation).to_a.map { |value| value.to_mm / 1000.0 } }
        end
      end

      def mirrored?(transformation)
        origin = ORIGIN.transform(transformation)
        x, y, z = [[1, 0, 0], [0, 1, 0], [0, 0, 1]].map { |p| Geom::Point3d.new(p).transform(transformation) - origin }
        x.cross(y).dot(z).negative?
      end

      def add_openings(storey, group, copy, params, token, metadata, openings)
        profiles = API.wall_profiles(params)
        fills = group.entities.grep(Sketchup::ComponentInstance).filter_map do |part|
          id = part.get_attribute(API::DICT, 'opening_id')
          [id, part] if id
        end.to_h
        copy.definition.entities.grep(Sketchup::ComponentInstance).each do |part|
          part.erase! if part.get_attribute(API::DICT, 'opening_id')
        end
        params.fetch('openings', []).each do |opening|
          id = opening.fetch('id')
          mark = opening['mark'].to_s
          name = mark.empty? ? Openings::TYPES.fetch(opening.fetch('kind')) : mark
          entry = { token: "#{token}/opening/#{id}", wall: token, name: name,
                    mirrored: mirrored?(group.transformation),
                    points: opening_points(group, params, opening, profiles.fetch(opening.fetch('segment'))),
                    properties: { 'OpeningKind' => Openings::TYPES.fetch(opening.fetch('kind')), 'Mark' => mark,
                                  'NominalWidth' => opening.fetch('width') / 1000.0,
                                  'NominalHeight' => opening.fetch('height') / 1000.0,
                                  'SillHeight' => opening.fetch('sill') / 1000.0 } }
          door = Doors.filled?(opening)
          if door || opening['sash'] || opening['window_type']
            part = fills[id]
            raise ArgumentError, "建具「#{name}」の形状が見つかりません。" unless part

            classification = door ? 'IfcDoor' : 'IfcWindow'
            fill = "#{token}_#{door ? 'DOOR' : 'WINDOW'}_#{openings.size + 1}"
            component(storey, part, group.transformation * part.transformation, fill, classification)
            properties = { 'Mark' => mark }
            if door
              properties['DoorType'] = Openings.label(opening)
              direction = Doors.direction(opening)
              properties['DoorDirection'] = Doors.direction_options(Doors.type(opening)).fetch(direction) if direction
              properties['InactiveLeafWidth'] = opening['inactive_width'] / 1000.0 if opening['inactive_width']
            else
              mount = Openings.window_mount(opening)
              properties.merge!('WindowType' => Openings.label(opening),
                                'Mounting' => Openings::WINDOW_MOUNTS.fetch(mount.fetch('mode')),
                                'MountingOffset' => mount.fetch('offset') / 1000.0)
              properties['ProductId'] = opening['sash']['product_id'] if opening['sash']
            end
            metadata[fill] = { ifc: classification.upcase, name: name, stable_key: "#{token}/fill/#{id}",
                               width: opening.fetch('width') / 1000.0, height: opening.fetch('height') / 1000.0,
                               properties: properties }
            entry[:fill] = fill
          end
          openings << entry
        end
      end

      def stage(model, groups)
        metadata = {}
        openings = []
        levels = API.levels(model)
        storeys = {}
        groups.each do |group|
          kind = Follow.kind(group)
          params = Follow.parameters(group)
          level, height = elevation_for(params, levels)
          storey = storeys[level] ||= begin
            key = "SBR_STOREY_#{storeys.size + 1}"
            node = model.entities.add_group
            node.transformation = Geom::Transformation.translation(API.point(0, 0, height || 0))
            classify(node, key, 'IfcBuildingStorey')
            metadata[key] = { ifc: 'IFCBUILDINGSTOREY', name: level, elevation: height && height / 1000.0,
                              stable_key: "storey:#{level}" }
            node
          end
          token = "SBR_ELEMENT_#{group.persistent_id}"
          type, quantity, predefined = CLASSES.fetch(kind)
          copy = component(storey, group, group.transformation, token, type)
          metadata[token] = { ifc: type.upcase, name: group.name.empty? ? API.object_name(kind) : group.name,
                              predefined: predefined || '.NOTDEFINED.', qto: quantity,
                              volume: Schedule.volume(group, kind), properties: properties(group, params, level) }
          add_openings(storey, group, copy, params, token, metadata, openings) if kind == 'wall'
        end
        [storeys.values, metadata, openings]
      end

      def native_export(model, file, groups)
        original_selection = model.selection.to_a
        model.start_operation('IFC書き出し用の一時形状', true)
        begin
          schema!(model)
          selection, metadata, openings = stage(model, groups)
          model.selection.clear
          model.selection.add(selection)
          options = { ifc_version: SCHEMA, standard_ifc_hierarchy: true, selectionset_only: true,
                      hidden_geometry: true, tessellated_geometry: true, show_summary: false }
          raise ArgumentError, 'SketchUpのIFC書き出しに失敗しました。' unless model.export(file, options) && File.file?(file)

          [metadata, openings]
        ensure
          model.abort_operation
          model.selection.clear
          model.selection.add(original_selection.select(&:valid?)) unless original_selection.empty?
        end
      end

      def export(model, file)
        API.top_level!(model)
        WallHeads.check_current!(model)
        raise ArgumentError, 'IFC4書き出しはSketchUp 2026以降が必要です。' if Sketchup.version.to_i < 26
        raise ArgumentError, '先にSKPを保存してください。' if model.path.empty?

        file += '.ifc' unless File.extname(file).casecmp?('.ifc')
        raise ArgumentError, '別のファイル名で保存してください。' if File.exist?(file)

        groups = sources(model)
        raise ArgumentError, 'IFCに出す建築部材がありません。' if groups.empty?

        Dir.mktmpdir('sbr-ifc-') do |directory|
          temporary = File.join(directory, 'native.ifc')
          metadata, openings = native_export(model, temporary, groups)
          data = IfcStep.new(File.read(temporary, encoding: 'UTF-8'), File.expand_path(model.path))
                        .export(metadata, openings, File.basename(file))
          File.open(file, File::WRONLY | File::CREAT | File::EXCL, 0o666) { |output| output.binmode; output.write(data) }
          { elements: groups.size, openings: openings.size,
            windows: metadata.values.count { |item| item[:ifc] == 'IFCWINDOW' },
            doors: metadata.values.count { |item| item[:ifc] == 'IFCDOOR' } }
        end
      end

      def choose_file(model)
        file = UI.savepanel('建築部材をIFC4で書き出し', '', "#{model.title}.ifc")
        export(model, file) if file
      end
    end
  end
end
