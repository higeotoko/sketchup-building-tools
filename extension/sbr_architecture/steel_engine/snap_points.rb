# frozen_string_literal: true
module SbrArchitectureBundled
  module Steel
    module SnapPoints
      # Reference points at each end and midpoint, without loose edges.
      def self.add(group, length_mm, height_mm, references: nil)
        entities = group.entities
        old = entities.grep(Sketchup::ConstructionPoint).select { |p| p.get_attribute(SNAP_DICTIONARY,'owned',false) }
        entities.erase_entities(old) unless old.empty?
        references ||= [[0.0,0.0],[0.0,height_mm/2.0],[0.0,-height_mm/2.0]]
        [0.0,length_mm/2.0,length_mm].product(references).map do |x,(y,z)|
          point = entities.add_cpoint(Geom::Point3d.new(x.mm,y.mm,z.mm))
          point.set_attribute(SNAP_DICTIONARY,'owned',true)
          point.layer = group.model.layers[0]
          point
        end
      end

      # Inspect only groups under the cursor, not the entire model. Native
      # inference may choose a front face before a guide inside the steel.
      def self.pick(view,x,y, group_filter: nil, point_filter: nil)
        return nil if view.model.rendering_options['HideConstructionGeometry']
        helper=view.pick_helper
        helper.do_pick(x,y,10)
        candidates=[]
        seen={}
        helper.count.times do |index|
          transform=view.model.edit_transform
          helper.path_at(index).each do |entity|
            next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            transform=transform*entity.transformation
            next unless group_filter ? group_filter.call(entity) : entity.attribute_dictionary(DICTIONARY,false)
            key=[entity.persistent_id,transform.to_a]
            next if seen[key]
            seen[key]=true
            MemberReader.entities(entity).grep(Sketchup::ConstructionPoint).each do |point|
              eligible = point_filter ? point_filter.call(point) : point.get_attribute(SNAP_DICTIONARY,'owned',false)
              next unless eligible && !point.hidden? && point.layer.visible?
              world=point.position.transform(transform)
              screen=view.screen_coords(world)
              distance=Math.hypot(screen.x-x,screen.y-y)
              candidates << [distance,world.distance(view.camera.eye).to_f,world] if distance<=10
            end
          end
        end
        candidates.min_by { |distance,depth,_point| [distance,depth] }&.last
      end

      def self.refresh_selected(model=Sketchup.active_model)
        groups = model.selection.grep(Sketchup::Group).select { |g| g.attribute_dictionary(DICTIONARY,false) }
        raise Error, '鋼材のGroupを選択してください。複数選択もできます。' if groups.empty?
        # Validate every selection before mutating any of them.
        entries = groups.map { |g| [g,MemberReader.read((model.active_path || [])+[g])] }
        opened = false
        model.start_operation('鋼材にスナップ点を追加',true)
        opened = true
        entries.each do |group,data|
          group.make_unique
          references=data['snap_reference_points_mm_json'] ? JSON.parse(data['snap_reference_points_mm_json']) : nil
          add(group,data['length'],data['H'],references: references)
          raise Error, 'ガイド点追加後にSolidを維持できませんでした。' unless group.manifold?
          group.set_attribute(DICTIONARY,'geometry_signature',MemberReader.signature(group))
        end
        model.commit_operation
        opened = false
        Sketchup.status_text = "#{groups.size}本にスナップ用ガイド点を追加しました。"
      rescue StandardError
        model.abort_operation if opened
        raise
      end
    end
  end
end
