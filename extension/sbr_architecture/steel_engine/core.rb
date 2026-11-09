# frozen_string_literal: true
require 'json'
require 'digest'

module SbrArchitectureBundled
  module Steel
    VERSION = '1.9.0' unless const_defined?(:VERSION)
    DICTIONARY = 'HigeMeganeTools.StructuralMember' unless const_defined?(:DICTIONARY)
    SNAP_DICTIONARY = 'HigeMeganeTools.SnapPoints' unless const_defined?(:SNAP_DICTIONARY)
    class Error < StandardError; end

    module Log
      def self.error(error)
        warn("[HigeMegane Steel] #{error.class}: #{error.message}")
        warn(error.backtrace.join("\n")) if Sketchup.read_default('HigeMeganeSteel', 'debug', false)
      end
    end

    class Boundary
      attr_reader :vertices
      def initialize(data)
        raise Error, '未対応の輪郭形式です。' unless data.fetch('kind','polyline_bulge') == 'polyline_bulge'
        raise Error, '閉じたYZ断面が必要です。' unless data['closed'] && data['coordinates'] == 'YZ'
        @vertices = data.fetch('vertices_y_z_bulge').map do |point|
          raise Error, '断面頂点が不正です。' unless point.size == 3
          point.map { |v| Float(v) }.freeze
        end.freeze
        raise Error, '断面座標が不正です。' if @vertices.size < 4 || !@vertices.flatten.all?(&:finite?)
      end

      # Exact bulges remain in the library. Only the display mesh is tessellated.
      def points_mm
        @points_mm ||= begin
          result = []
          @vertices.each_with_index do |(y, z, bulge), i|
            ny, nz, = @vertices[(i + 1) % @vertices.size]
            chord = Math.hypot(ny - y, nz - z)
            raise Error, '重複した断面頂点があります。' if chord < 0.001
            result << [y, z].freeze
            next if bulge.abs < 1e-12
            sweep = 4 * Math.atan(bulge)
            radius = chord * (1 + bulge**2) / (4 * bulge.abs)
            cy = (y + ny) / 2 - (nz - z) * (1 - bulge**2) / (4 * bulge)
            cz = (z + nz) / 2 + (ny - y) * (1 - bulge**2) / (4 * bulge)
            start = Math.atan2(z - cz, y - cy)
            step = [Math::PI / 12, 2 * Math.acos([1 - 0.02 / radius, -1].max)].min
            count = [(sweep.abs / step).ceil, 1].max
            raise Error, '円弧の分割数が大きすぎます。' if count > 4096
            (1...count).each do |j|
              angle = start + sweep * j / count
              result << [cy + radius * Math.cos(angle), cz + radius * Math.sin(angle)].freeze
            end
          end
          # Normalize to CCW in YZ; positive normal is local +X.
          area = result.each_with_index.sum { |(y,z),i| ny,nz=result[(i+1)%result.size]; y*nz-ny*z }
          result.reverse! if area < 0
          raise Error, '断面面積がありません。' if area.abs < 1e-6
          result.freeze
        end
      end
    end

    # Boundary encoding can grow to Circle without changing Member or Builder.
    class Profile
      attr_reader :outer_loop, :inner_loops
      def initialize(data)
        @outer_loop = Boundary.new(data.fetch('outer_loop',data))
        @inner_loops = data.fetch('inner_loops',[]).map { |loop| Boundary.new(loop) }.freeze
        validate_holes!
      end
      def points_mm; @outer_loop.points_mm; end
      def vertices; @outer_loop.vertices; end
      def loops_mm; [points_mm,*@inner_loops.map(&:points_mm)]; end
      def self.area(points)
        points.each_with_index.sum { |(y,z),i| ny,nz=points[(i+1)%points.size]; y*nz-ny*z }.abs/2.0
      end
      def area_mm2
        self.class.area(points_mm)-@inner_loops.sum { |loop| self.class.area(loop.points_mm) }
      end
      def self.inside?(point,polygon)
        x,y=point
        inside=false
        polygon.each_with_index do |(ax,ay),i|
          bx,by=polygon[(i+1)%polygon.size]
          inside = !inside if ((ay>y)!=(by>y)) && x<(bx-ax)*(y-ay)/(by-ay)+ax
        end
        inside
      end
      def self.cross(a,b,c)
        (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
      end
      def self.intersects?(a,b,c,d)
        return false if [a[0],b[0]].max < [c[0],d[0]].min-1e-8 || [c[0],d[0]].max < [a[0],b[0]].min-1e-8
        return false if [a[1],b[1]].max < [c[1],d[1]].min-1e-8 || [c[1],d[1]].max < [a[1],b[1]].min-1e-8
        cross(a,b,c)*cross(a,b,d)<=1e-12 && cross(c,d,a)*cross(c,d,b)<=1e-12
      end
      def self.boundaries_intersect?(a,b)
        a.each_with_index.any? do |p,i|
          b.each_with_index.any? { |q,j| intersects?(p,a[(i+1)%a.size],q,b[(j+1)%b.size]) }
        end
      end
      def validate_holes!
        loops=@inner_loops.map(&:points_mm)
        loops.each do |hole|
          unless hole.all? { |p| self.class.inside?(p,points_mm) } && !self.class.boundaries_intersect?(hole,points_mm)
            raise Error, '内周が外周の内部にありません。'
          end
        end
        loops.combination(2).each do |a,b|
          if self.class.boundaries_intersect?(a,b) || self.class.inside?(a[0],b) || self.class.inside?(b[0],a)
            raise Error, '内周同士が重複しています。'
          end
        end
        raise Error, '中空断面の面積が不正です。' unless area_mm2>0
      end
    end

    class Section
      attr_reader :id, :name, :dimensions, :profile, :family, :standard, :subtype, :reference
      def initialize(data)
        @id, @name = data.fetch('id'), data.fetch('name')
        @family = data.fetch('family',data.fetch('section_type'))
        raise Error, '未対応の断面Familyです。' unless %w[H BOX ANGLE C CHANNEL I PIPE FB CT HB SB RB].include?(@family)
        @standard = data.fetch('standard','general')
        @subtype = data.fetch('subtype',@family)
        @reference = data.fetch('reference',{'profile_origin'=>'bbox_center','member_axis_mm'=>[0,0],'centroid_mm'=>nil}).freeze
        @dimensions = data.fetch('dimensions_mm').transform_values { |v| Float(v) }.freeze
        required = %w[H I CHANNEL].include?(@family) ? %w[H B tw tf] : %w[H B t]
        required = %w[H B D t] if @family=='PIPE'
        required = %w[H B lip t] if @family=='C'
        required = %w[H B tw tf r] if @family=='CT'
        required = %w[H B S] if %w[HB SB].include?(@family)
        required = %w[H B D] if @family=='RB'
        required = %w[H B t_vertical t_horizontal] if @family=='ANGLE' && @subtype=='UnequalThickness'
        raise Error, '断面寸法が不正です。' unless required.all? { |k| @dimensions[k]&.finite? && @dimensions[k] > 0 }
        if @family=='CT'
          h,b,tw,tf,r=@dimensions.values_at('H','B','tw','tf','r')
          raise Error, 'T断面の寸法・フィレットが不正です。' unless tw+2*r<b && tf+r<h
        elsif %w[HB SB RB].include?(@family)
          size=@dimensions[@family=='RB' ? 'D' : 'S']
          width=@family=='HB' ? 2*size/Math.sqrt(3) : size
          raise Error, '棒鋼の公称寸法が一致しません。' unless (@dimensions['H']-size).abs<1e-6 && (@dimensions['B']-width).abs<1e-6
        end
        if @family == 'ANGLE'
          equal=(@dimensions['H']-@dimensions['B']).abs<1e-6
          valid = (@subtype=='Equal' && equal) || (%w[Unequal UnequalThickness].include?(@subtype) && !equal)
          raise Error, 'ANGLEの分類と寸法が一致しません。' unless valid
        end
        axis=@reference.fetch('member_axis_mm',[0,0])
        raise Error, '部材軸の断面内位置が不正です。' unless axis.is_a?(Array) && axis.size==2 && axis.all? { |n| n.is_a?(Numeric) && n.finite? }
        @profile = Profile.new(data.fetch('profile'))
        expected_holes = %w[BOX PIPE].include?(@family) ? 1 : 0
        raise Error, '断面Familyと内周数が一致しません。' unless @profile.inner_loops.size == expected_holes
        points = @profile.points_mm
        b = points.map(&:first).minmax
        h = points.map(&:last).minmax
        unless (b[1]-b[0]-@dimensions['B']).abs < 0.05 && (h[1]-h[0]-@dimensions['H']).abs < 0.05
          raise Error, "断面寸法が一致しません: #{@name}"
        end
      end
      def summary
        { id: @id, name: @name, dimensions: @dimensions, family: @family, standard: @standard, subtype: @subtype,
          rotations: rotations, placement_references: placement_references }
      end
      def rotations; %w[ANGLE C CHANNEL CT].include?(@family) ? [0,90,180,270] : [0,90]; end
      def placement_references; @family=='ANGLE' ? %w[center outer_top outer_heel outer_right] : %w[center top bottom]; end
      def member_axis_mm; @reference.fetch('member_axis_mm',[0,0]); end
      # Raw DXF geometry is expressed relative to Profile Origin. SketchUp mesh
      # coordinates are relative to Member Axis, a separate explicit point.
      def geometry_loops_mm
        @geometry_loops_mm ||= @profile.loops_mm.map do |loop|
          loop.map { |y,z| [y-member_axis_mm[0],z-member_axis_mm[1]].freeze }.freeze
        end.freeze
      end
      def geometry_bounds_mm
        points=geometry_loops_mm.first
        [points.map(&:first).minmax,points.map(&:last).minmax]
      end
      def placement_point_mm(reference)
        raise Error, 'この断面では選択した配置基準を使用できません。' unless placement_references.include?(reference)
        return [0.0,0.0] if reference=='center'
        ys,zs=geometry_bounds_mm
        return [ys.first,zs.last] if reference=='outer_top'
        return [ys.first,zs.first] if reference=='outer_heel'
        return [ys.last,zs.first] if reference=='outer_right'
        [(ys.first+ys.last)/2.0,reference=='top' ? zs.last : zs.first]
      end
      def snap_reference_points_mm
        placement_references.map { |reference| placement_point_mm(reference) }
      end
    end

    class Library
      def initialize(path)
        definitions = Array(path).flat_map do |file|
          data = JSON.parse(File.read(file, encoding: 'UTF-8'))
          raise Error, '未対応の断面ライブラリ形式です。' unless [1,2].include?(data['schema_version']) && data['units'] == 'mm'
          data.fetch('sections')
        end
        @by_id = definitions.to_h { |s| [s.fetch('id'), s] }.freeze
        raise Error, '断面ライブラリが空、またはIDが重複しています。' if @by_id.empty? || @by_id.size != definitions.size

        # Search uses catalogue metadata. The original Section validation runs
        # when a particular profile is selected for preview or construction.
        @options = definitions.map do |s|
          [s.fetch('id'), s.fetch('name'), s.fetch('family', s['section_type']), *s.fetch('dimensions_mm').values_at('H', 'B')].freeze
        end.freeze
        @sections = {}
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError, SystemCallError => e
        raise Error, "断面ライブラリを読み込めません: #{e.message}"
      end
      attr_reader :options
      def sections
        @by_id.keys.map { |id| fetch(id) }.freeze
      end
      def fetch(id)
        definition = @by_id.fetch(id) { raise Error, "断面が見つかりません: #{id}" }
        @sections[id] ||= Section.new(definition)
      end
    end

    module Frame
      def self.build(start_point, end_point, rotation_deg)
        x = end_point - start_point
        raise Error, '部材長は1mm以上にしてください。' if x.length < 1.mm
        x.normalize!
        up = Geom::Vector3d.new(0, 0, 1)
        # The vertical fallback avoids an undefined cross product.
        up = Geom::Vector3d.new(0, 1, 0) if x.cross(up).length.to_f < 1e-6
        y = up.cross(x).normalize
        z = x.cross(y).normalize
        spin = Geom::Transformation.rotation(ORIGIN, x, rotation_deg.degrees)
        Geom::Transformation.axes(start_point, x, y.transform(spin), z.transform(spin))
      end
      def self.rigid?(transform)
        # Transformation#xaxis et al. return normalized directions in SketchUp.
        # Transform basis points to retain the actual scale, including homogeneous scale.
        origin = Geom::Point3d.new(0,0,0).transform(transform)
        axes = [[1,0,0],[0,1,0],[0,0,1]].map { |p| Geom::Point3d.new(p).transform(transform) - origin }
        axes.all? { |a| (a.length.to_f-1).abs < 1e-6 } &&
          axes.combination(2).all? { |a,b| a.dot(b).abs < 1e-6 } &&
          axes[0].cross(axes[1]).dot(axes[2]) > 0.999999
      end
    end

    # Immutable generation parameters; geometry building is a separate service.
    class Member
      attr_reader :section, :start_point, :end_point, :rotation, :length, :placement_reference
      def initialize(section, start_point, end_point, rotation=0, placement_reference='center')
        @section = section
        @start_point, @end_point = Geom::Point3d.new(start_point), Geom::Point3d.new(end_point)
        @rotation = Float(rotation)
        raise Error, '座標または角度が不正です。' unless [*@start_point.to_a,*@end_point.to_a,@rotation].all?(&:finite?)
        @rotation %= 360
        @length = @start_point.distance(@end_point)
        raise Error, '部材長は1mm以上にしてください。' if @length < 1.mm
        @placement_reference = placement_reference
        raise Error, '配置基準が不正です。' unless @section.placement_references.include?(@placement_reference)
        # Reference points and the member axis are independent of Profile Origin.
        frame = Frame.build(@start_point, @end_point, @rotation)
        ref_y,ref_z = @section.placement_point_mm(@placement_reference)
        offset = Geom::Vector3d.new(frame.yaxis.to_a.zip(frame.zaxis.to_a).map { |y,z| -ref_y.mm.to_f*y-ref_z.mm.to_f*z })
        @start_point = @start_point + offset
        @end_point = @end_point + offset
      end
      def reference_z_mm
        @section.placement_point_mm(@placement_reference)[1]
      end
      def transformation
        Frame.build(@start_point, @end_point, @rotation)
      end
      def attributes
        { 'schema_version'=>1, 'plugin_version'=>VERSION, 'member_type'=>'steel_member',
          'section_type'=>@section.family, 'family'=>@section.family, 'standard'=>@section.standard,
          'subtype'=>@section.subtype, 'section_name'=>@section.name, 'section_id'=>@section.id,
          'coordinate_system'=>'member_local', 'units'=>'mm',
          'start_point'=>[0.0,0.0,0.0], 'end_point'=>[@length.to_mm,0.0,0.0],
          'length'=>@length.to_mm, 'axis_vector'=>[1.0,0.0,0.0],
          'section_rotation'=>@rotation, 'material'=>'unknown',
          'profile_origin'=>@section.reference.fetch('profile_origin'),
          'member_axis_in_profile_mm'=>@section.member_axis_mm,
          'snap_reference_points_mm_json'=>JSON.generate(@section.snap_reference_points_mm),
          'placement_reference'=>@placement_reference,
          'reference_start_point'=>[0.0,*@section.placement_point_mm(@placement_reference)],
          'reference_end_point'=>[@length.to_mm,*@section.placement_point_mm(@placement_reference)] }.merge(@section.dimensions)
      end
    end

    module MemberReader
      def self.entities(instance)
        instance.is_a?(Sketchup::Group) ? instance.entities : instance.definition.entities
      end
      def self.signature(instance)
        # Detect direct geometry edits without observers; transforms are intentionally excluded.
        rows = entities(instance).filter_map do |e|
          # Owned guide points are nonphysical and may be deleted via Delete Guides.
          next if e.is_a?(Sketchup::ConstructionPoint) && e.get_attribute(SNAP_DICTIONARY,'owned',false)
          if e.is_a?(Sketchup::Edge)
            ['E', *e.vertices.map { |v| v.position.to_a.map { |n| n.round(8) } }.sort].to_json
          elsif e.is_a?(Sketchup::Face)
            ['F', e.loops.map { |l| l.vertices.map { |v| v.position.to_a.map { |n| n.round(8) } }.sort }.sort,
             e.normal.to_a.map { |n| n.round(8) }].to_json
          else
            ['UNSUPPORTED',e.typename].to_json
          end
        end
        Digest::SHA256.hexdigest(rows.sort.join("\n"))
      end
      def self.read(path)
        # A full InstancePath is required for nested objects; never guess a shared parent.
        instance_path = path.is_a?(Sketchup::InstancePath) ? path : Sketchup::InstancePath.new(path)
        instance = instance_path.to_a.last
        raise Error, '部材のInstancePathが不正です。' unless instance.is_a?(Sketchup::Group) || instance.is_a?(Sketchup::ComponentInstance)
        dict = instance.attribute_dictionary(DICTIONARY, false)
        raise Error, '構造部材属性がありません。' unless dict && dict['schema_version'] == 1
        raise Error, '形状が手編集されています。部材の再生成が必要です。' unless dict['geometry_signature'] == signature(instance)
        transform = instance_path.transformation
        raise Error, '拡大縮小・鏡像・せん断を検出しました。寸法情報を利用できません。' unless Frame.rigid?(transform)
        data = dict.to_h
        start = Geom::Point3d.new(data['start_point'].map(&:mm)).transform(transform)
        finish = Geom::Point3d.new(data['end_point'].map(&:mm)).transform(transform)
        reference_start = Geom::Point3d.new((data['reference_start_point'] || data['start_point']).map(&:mm)).transform(transform)
        reference_end = Geom::Point3d.new((data['reference_end_point'] || data['end_point']).map(&:mm)).transform(transform)
        data.merge('coordinate_system'=>'world', 'start_point'=>start.to_a.map(&:to_mm),
                   'end_point'=>finish.to_a.map(&:to_mm), 'length'=>start.distance(finish).to_mm,
                   'placement_reference'=>data.fetch('placement_reference','center'),
                   'reference_start_point'=>reference_start.to_a.map(&:to_mm),
                   'reference_end_point'=>reference_end.to_a.map(&:to_mm),
                   'axis_vector'=>transform.xaxis.to_a, 'local_y'=>transform.yaxis.to_a,
                   'local_z'=>transform.zaxis.to_a)
      end
    end
  end
end

