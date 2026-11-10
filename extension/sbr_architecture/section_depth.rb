# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class SectionDepth
      MIN_FACE_ALTITUDE = 0.001 # SketchUp's vertex tolerance, in inches.

      def self.sources(model)
        model.entities.select do |item|
          (container?(item) || primitive?(item) || item.is_a?(Sketchup::Image)) &&
            !item.layer.get_attribute(Drawings::META, 'key')
        end
      end

      def self.container?(item)
        item.is_a?(Sketchup::Group) || item.is_a?(Sketchup::ComponentInstance)
      end

      def self.primitive?(item)
        item.is_a?(Sketchup::Face) || item.is_a?(Sketchup::Edge)
      end

      def initialize(point, eye, depth, visibility)
        @axis = eye.to_a.index { |value| !value.zero? }
        @sign = eye.to_a.fetch(@axis)
        @limit = @sign * point.to_a.fetch(@axis).to_f - depth.mm.to_f
        @visibility = visibility
      end

      def extent(box, transform)
        return :inside unless box.valid?

        low, high = 8.times.map { |i| distance(box.corner(i).transform(transform)) }.minmax
        return :beyond if high < 0
        return :inside if low >= 0

        :crossing
      end

      def apply(annotation, sources, name: '断面の表示範囲')
        hidden = []
        cropped = []
        sources.each do |item|
          case extent(item.bounds, IDENTITY)
          when :beyond
            hidden << item
          when :crossing
            cropped << item unless item.is_a?(Sketchup::Image)
          end
        end
        unless cropped.empty?
          copy = annotation.entities.add_group
          copy.name = name
          copy.layer = annotation.model.layers[0]
          write(copy.entities, cropped, IDENTITY, nil, root: true)
        end
        [hidden + cropped, { depth_hidden: hidden.size, depth_cropped: cropped.size }]
      end

      def distance(point)
        @sign * point.to_a.fetch(@axis).to_f - @limit
      end

      def intersection(a, b, da, db)
        Geom.linear_combination(db / (db - da), a, da / (da - db), b)
      end

      def polygon(points)
        points.zip(points.rotate).flat_map do |a, b|
          da, db = distance(a), distance(b)
          result = []
          result << a if da >= 0
          result << intersection(a, b, da, db) if da.negative? != db.negative?
          result
        end.each_with_object([]) { |point, unique| unique << point unless unique.include?(point) }
      end

      def segment(a, b)
        da, db = distance(a), distance(b)
        return if da < 0 && db < 0
        return [a, b] if da >= 0 && db >= 0

        point = intersection(a, b, da, db)
        da < 0 ? [point, b] : [a, point]
      end

      def write(target, source, transform, material, root: false)
        visible = root ? source : source.select do |item|
          !@visibility.fetch(item.persistent_id) { item.hidden? } && item.layer.visible?
        end
        geometry = visible.select { |item| self.class.primitive?(item) }
        write_primitives(target, geometry, transform, material) unless geometry.empty?
        visible.select { |item| self.class.container?(item) }.each do |item|
          placement = transform * item.transformation
          case extent(item.bounds, transform)
          when :inside
            copy = target.add_instance(item.definition, placement)
            copy.layer = target.model.layers[0]
            copy.material = item.material || material
          when :crossing
            copy = target.add_group
            copy.layer = target.model.layers[0]
            write(copy.entities, item.definition.entities.grep(Sketchup::Drawingelement), placement, item.material || material)
          end
        end
      end

      def write_primitives(target, source, transform, material)
        target.build do |builder|
          source.grep(Sketchup::Face).each do |face|
            mesh = face.mesh
            mesh.polygons.each do |indices|
              points = polygon(indices.map { |index| mesh.point_at(index.abs).transform(transform) })
              points.drop(1).each_cons(2) do |a, b|
                origin = points.first
                u, v = a - origin, b - origin
                longest = [u.length, v.length, a.distance(b)].max
                next if u.cross(v).length <= longest * MIN_FACE_ALTITUDE

                copy = builder.add_face([origin, a, b])
                next unless copy

                copy.material = face.material || material
                copy.back_material = face.back_material || material
                copy.edges.each { |edge| edge.hidden = true }
              end
            end
          end
          source.grep(Sketchup::Edge).each do |edge|
            points = segment(*edge.vertices.map { |vertex| vertex.position.transform(transform) })
            next unless points && points[0] != points[1]

            copy = builder.add_edge(points)
            next unless copy

            copy.hidden = false
            copy.soft = edge.soft?
            copy.smooth = edge.smooth?
            copy.material = edge.material if edge.material
          end
        end
        target.each { |item| item.layer = target.model.layers[0] }
      end
    end
  end
end
