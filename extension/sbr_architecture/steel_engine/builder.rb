# frozen_string_literal: true
require_relative 'snap_points'
module SbrArchitectureBundled
  module Steel
    module Builder
      # The architectural tool owns the operation and the group's parent transform.
      def self.populate(group, member)
        loops = member.section.geometry_loops_mm
        points = loops.first.map { |y,z| Geom::Point3d.new(0,y.mm,z.mm) }
        face = group.entities.add_face(points)
        raise Error, '断面の面を生成できませんでした。' unless face && face.valid?
        loops.drop(1).each do |loop|
          hole = group.entities.add_face(loop.map { |y,z| Geom::Point3d.new(0,y.mm,z.mm) })
          raise Error, '内周面を生成できませんでした。' unless hole && hole.valid? && hole != face
          hole.erase!
        end
        faces = group.entities.grep(Sketchup::Face)
        face = faces.find { |f| f.loops.size == member.section.profile.inner_loops.size+1 }
        raise Error, '断面の穴を形成できませんでした。' unless faces.size == 1 && face
        face.reverse! if face.normal.x < 0
        face.pushpull(member.length)
        group.entities.each { |entity| entity.layer = group.model.layers[0] if entity.respond_to?(:layer=) }
        raise Error, '閉じたSolidを生成できませんでした。' unless group.manifold? && group.volume > 0
        # Smooth only internal facets of a fillet, leaving flange/web corners crisp.
        group.entities.grep(Sketchup::Edge).each do |edge|
          next unless edge.faces.size == 2 && edge.line[1].parallel?(X_AXIS)
          if edge.faces[0].normal.angle_between(edge.faces[1].normal) < 20.degrees
            edge.soft = true
            edge.smooth = true
          end
        end
        group.transformation = member.transformation
        SnapPoints.add(group,member.length.to_mm,member.section.dimensions['H'],references: member.section.snap_reference_points_mm)
        raise Error, 'ガイド点追加後にSolidを維持できませんでした。' unless group.manifold?
        instance = group
        member.attributes.each { |k,v| instance.set_attribute(DICTIONARY,k,v) }
        instance.set_attribute(DICTIONARY,'geometry_signature',MemberReader.signature(instance))
        instance
      end
    end
  end
end
