# frozen_string_literal: true

require 'digest'

module Higeotoko
  module SbrArchitecture
    # The native exporter provides IFC geometry. This adapter only replaces
    # known product fields and appends relationships and measured quantities.
    class IfcStep
      ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$'
      RECORD = /\A\s*#(\d+)\s*=\s*([A-Z][A-Z0-9_]+)\s*\((.*)\);\s*\z/
      GUID_STRING = /'([0123][A-Za-z0-9_$]{21})'/
      TRIANGLES = [[1, 3, 2], [1, 4, 3], [5, 6, 7], [5, 7, 8], [1, 2, 6], [1, 6, 5],
                   [2, 3, 7], [2, 7, 6], [3, 4, 8], [3, 8, 7], [4, 1, 5], [4, 5, 8]].freeze

      def initialize(source, seed)
        @source = source
        @seed = seed
        @records = {}
        @replacements = {}
        @guids = {}
        @names = {}
        @extra = []
        source.each_line do |line|
          match = RECORD.match(line)
          @records[match[1].to_i] = [match[2], match[3]] if match
        end
        @last = @records.keys.max || 0
        @products = {}
      end

      def args(value)
        result = []
        start, depth = 0, 0
        quoted = false
        value.each_char.with_index do |character, index|
          if character == "'"
            quoted = !quoted
          elsif !quoted
            case character
            when '(' then depth += 1
            when ')' then depth -= 1
            when ','
              if depth.zero?
                result << value[start...index].strip
                start = index + 1
              end
            end
          end
        end
        result << value[start..].strip
      end

      def quote(value)
        text = value.to_s
        if text.ascii_only? && !text.match?(/[\x00-\x1f\\]/)
          "'#{text.gsub("'", "''")}'"
        else
          "'\\X2\\#{text.encode('UTF-16BE').unpack1('H*').upcase}\\X0\\'"
        end
      end

      def guid(key)
        number = Digest::SHA256.hexdigest("#{@seed}|#{key}")[0, 32].to_i(16)
        quote(Array.new(22) { offset = number & 63; number >>= 6; ALPHABET[offset] }.reverse.join)
      end

      def number(value)
        value = Float(value)
        raise ArgumentError, 'IFC数量に無効な数値があります。' unless value.finite?

        "#{format('%.10f', value).sub(/0+\z/, '')}"
      end

      def add(type, values)
        @last += 1
        @extra << "##{@last}= #{type}(#{values.join(',')});\n"
        "##{@last}"
      end

      def root(type, key, *values)
        add(type, [guid(key), @owner, *values])
      end

      def require_native_context!
        unless @source.match?(/FILE_SCHEMA\s*\(\s*\(\s*'IFC4'\s*\)\s*\)/i) &&
               @records.values.any? { |type, raw| type == 'IFCSIUNIT' && raw.delete(' ') == '*,.LENGTHUNIT.,$,.METRE.' }
          raise ArgumentError, 'IFC4（メートル）の出力を確認できません。'
        end
        project = @records.values.find { |type, _| type == 'IFCPROJECT' }
        @owner = args(project.fetch(1))[1] if project
        context = @records.find { |_, (type, raw)| type == 'IFCGEOMETRICREPRESENTATIONSUBCONTEXT' && args(raw).first == "'Body'" }
        raise ArgumentError, 'IFCのプロジェクトまたは形状コンテキストが見つかりません。' unless @owner && context

        @context = "##{context.first}"
      end

      def identify(metadata)
        native = {}
        types = metadata.values.map { |entry| entry.fetch(:ifc) }.uniq
        @records.each do |id, (type, raw)|
          next unless types.include?(type)

          fields = args(raw)
          label = fields.fetch(2).delete("'")
          names = label.split
          token = names.uniq.size == 1 ? names.first : label
          next unless metadata.key?(token)
          raise ArgumentError, "IFC出力で同じ部材が重複しました（#{token}）。" if native.key?(token)

          native[token] = [id, type, fields]
        end
        unless native.keys.sort == metadata.keys.sort
          missing = metadata.keys - native.keys
          raise ArgumentError, "IFCに変換できなかった要素があります（#{missing.first(4).join(', ')}）。"
        end
        native.each do |token, (id, type, fields)|
          data = metadata.fetch(token)
          raise ArgumentError, "IFC分類が変わりました（#{data.fetch(:name)}）。" if type != data.fetch(:ifc)

          replacement = guid(data.fetch(:stable_key, token))
          @guids[fields[0]] = replacement
          fields[0] = replacement
          fields[2] = quote(data.fetch(:name))
          @names[quote(token)] = fields[2]
          if type == 'IFCBUILDINGSTOREY'
            fields[7] = fields[2]
            fields[8] = '.ELEMENT.'
            fields[9] = data[:elevation].nil? ? '$' : number(data.fetch(:elevation))
          elsif %w[IFCWINDOW IFCDOOR].include?(type)
            fields[8] = number(data.fetch(:height))
            fields[9] = number(data.fetch(:width))
            fields[10] = type == 'IFCWINDOW' ? '.WINDOW.' : '.DOOR.'
            fields[11] = '.NOTDEFINED.'
            fields[12] = '$'
          else
            fields[-1] = data.fetch(:predefined, '.NOTDEFINED.')
          end
          @products[token] = ["##{id}", fields[5]]
          @replacements[id] = "##{id}= #{type}(#{fields.join(',')});\n"
        end
      end

      def properties(token, data)
        reference = @products.fetch(token).first
        props = data.fetch(:properties, {}).map do |name, value|
          measure = value.is_a?(Numeric) ? "IFCLENGTHMEASURE(#{number(value)})" : "IFCTEXT(#{quote(value)})"
          add('IFCPROPERTYSINGLEVALUE', [quote(name), '$', measure, '$'])
        end
        if props.any?
          pset = root('IFCPROPERTYSET', "properties:#{token}", quote('Pset_SBR_Element'), '$', "(#{props.join(',')})")
          root('IFCRELDEFINESBYPROPERTIES', "properties-rel:#{token}", '$', '$', "(#{reference})", pset)
        end
        return unless data[:qto] && data[:volume]

        volume = add('IFCQUANTITYVOLUME', [quote('NetVolume'), '$', '$', number(data.fetch(:volume)), '$'])
        quantity = root('IFCELEMENTQUANTITY', "quantity:#{token}", quote(data.fetch(:qto)), '$', '$', "(#{volume})")
        root('IFCRELDEFINESBYPROPERTIES', "quantity-rel:#{token}", '$', '$', "(#{reference})", quantity)
      end

      def record_args(reference, type)
        record = @records[reference.delete_prefix('#').to_i]
        raise ArgumentError, "IFCの配置参照が不正です（#{reference}）。" unless record&.first == type

        args(record.last)
      end

      def vector(reference, type)
        record_args(reference, type).first.delete_prefix('(').delete_suffix(')').split(',').map { |value| Float(value) }
      end

      def to_local(points, placement, depth = 0)
        return points if placement == '$'
        raise ArgumentError, 'IFCの配置階層が深すぎます。' if depth >= 32

        parent, axes = record_args(placement, 'IFCLOCALPLACEMENT')
        location, z_axis, x_axis = record_args(axes, 'IFCAXIS2PLACEMENT3D')
        origin = vector(location, 'IFCCARTESIANPOINT')
        z = Geom::Vector3d.new(z_axis == '$' ? [0, 0, 1] : vector(z_axis, 'IFCDIRECTION')).normalize
        x0 = Geom::Vector3d.new(x_axis == '$' ? [1, 0, 0] : vector(x_axis, 'IFCDIRECTION')).normalize
        y = z.cross(x0).normalize
        x = y.cross(z).normalize
        to_local(points, parent, depth + 1).map do |point|
          displacement = Geom::Vector3d.new(point.zip(origin).map { |a, b| a - b })
          [x.dot(displacement), y.dot(displacement), z.dot(displacement)]
        end
      end

      def opening(data)
        token = data.fetch(:token)
        wall, wall_placement = @products.fetch(data.fetch(:wall))
        points = to_local(data.fetch(:points), wall_placement)
        location = add('IFCCARTESIANPOINT', ['(0.,0.,0.)'])
        axes = add('IFCAXIS2PLACEMENT3D', [location, '$', '$'])
        placement = add('IFCLOCALPLACEMENT', [wall_placement, axes])
        coords = points.map { |point| "(#{point.map { |value| number(value) }.join(',')})" }
        list = add('IFCCARTESIANPOINTLIST3D', ["(#{coords.join(',')})"])
        triangles = data[:mirrored] ? TRIANGLES.map(&:reverse) : TRIANGLES
        mesh = add('IFCTRIANGULATEDFACESET', [list, '$', '.T.', "(#{triangles.map { |triangle| "(#{triangle.join(',')})" }.join(',')})", '$'])
        shape = add('IFCSHAPEREPRESENTATION', [@context, quote('Body'), quote('Tessellation'), "(#{mesh})"])
        definition = add('IFCPRODUCTDEFINITIONSHAPE', ['$', '$', "(#{shape})"])
        item = root('IFCOPENINGELEMENT', token, quote(data.fetch(:name)), '$', '$', placement, definition, '$', '.OPENING.')
        @products[token] = [item, placement]
        root('IFCRELVOIDSELEMENT', "void:#{token}", '$', '$', wall, item)
        if data[:fill]
          root('IFCRELFILLSELEMENT', "fill:#{token}", '$', '$', item, @products.fetch(data.fetch(:fill)).first)
        end
        properties(token, data)
      end

      def export(metadata, openings, filename)
        require_native_context!
        identify(metadata)
        metadata.each { |token, data| properties(token, data) }
        openings.each { |data| opening(data) }
        data = @source.each_line.map do |line|
          match = /\A\s*#(\d+)\s*=/.match(line)
          if match
            (@replacements[match[1].to_i] || line)
              .gsub(GUID_STRING) { |quoted| @guids.fetch(quoted, quoted) }
              .gsub(/'SBR_[A-Z0-9_]+'/) { |quoted| @names.fetch(quoted, quoted) }
          elsif line.start_with?('FILE_NAME(')
            line.sub(/\AFILE_NAME\('[^']*'/) { "FILE_NAME(#{quote(filename)}" }
          else
            line
          end
        end.join
        finish = data.rindex(/^ENDSEC;/)
        raise ArgumentError, 'IFCのデータ終端が見つかりません。' unless finish

        data.insert(finish, @extra.join)
      end
    end
  end
end
