# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Doors
      API = SbrArchitecture
      DETAIL_VERSION = 2
      TYPES = {
        'single' => '片開き', 'double' => '両開き', 'unequal' => '親子開き',
        'surface' => '片引き（壁付け）', 'bypass' => '引違い（2枚）', 'split' => '引分け（壁付け）',
        'fold' => '折れ戸', 'empty' => '開口のみ'
      }.freeze
      HINGED = %w[single double unequal].freeze
      SURFACE = %w[surface split].freeze
      SIDES = { 'start_left' => '壁芯の左側', 'start_right' => '壁芯の右側' }.freeze
      MOTION = {
        'start_left' => '区間始点側・壁芯の左側', 'start_right' => '区間始点側・壁芯の右側',
        'end_left' => '区間終点側・壁芯の左側', 'end_right' => '区間終点側・壁芯の右側'
      }.freeze
      module_function

      def type(door)
        door.fetch('door_type', 'single')
      end

      def direction_key(door)
        return 'swing' if HINGED.include?(type(door))
        return 'motion' if %w[surface split fold].include?(type(door))
      end

      def direction_options(id)
        case id
        when 'single' then Openings::DOOR_SWINGS
        when 'unequal' then { 'none' => '閉じた状態' }.merge(Openings::DOOR_SWINGS.reject { |key, _| key == 'none' })
        when 'double' then { 'none' => '閉じた状態' }.merge(SIDES)
        when 'surface', 'fold' then MOTION
        when 'split' then SIDES
        else {}
        end
      end

      def settings(values, width)
        id = values.fetch('door_type', 'single')
        raise ArgumentError, '扉の形式を選んでください。' unless TYPES.key?(id)

        result = {}
        result['door_type'] = id if values.key?('door_type')
        key = direction_key(result)
        direction = values[key] if key
        if direction && !direction_options(id).key?(direction)
          raise ArgumentError, '扉の開き勝手または引く方向を選んでください。'
        end
        result[key] = direction if direction
        if id == 'unequal'
          inactive = Layout.mm(values.fetch('inactive_width', 300), '子扉幅', positive: true)
          raise ArgumentError, '子扉幅は開口幅の半分未満にしてください。' unless inactive < width / 2.0

          result['inactive_width'] = inactive
        end
        result
      end

      def direction(door)
        key = direction_key(door)
        door[key] || direction_options(type(door)).keys.first if key
      end

      def side(door)
        direction(door)&.split('_')&.last
      end

      def panes(door)
        x1, x2, = Openings.position(door)
        case type(door)
        when 'unequal'
          child = door.fetch('inactive_width')
          cut = direction(door).start_with?('end') ? x1 + child : x2 - child
          [[x1, cut], [cut, x2]]
        when 'double', 'bypass', 'split', 'fold'
          middle = (x1 + x2) / 2.0
          overlap = type(door) == 'bypass' ? [10, (x2 - x1) * 0.1].min : 0
          [[x1, middle + overlap], [middle - overlap, x2]]
        else
          [[x1, x2]]
        end
      end

      def swings(door, left, right)
        swing = Openings.door_swing(door)
        return [] unless swing

        handed, opening_side = swing
        lateral, sign = opening_side == 'left' ? [left, 1] : [right, -1]
        leaves = panes(door)
        leaves = [leaves.first.reverse] if leaves.one? && handed == 'end'
        leaves[-1] = leaves.last.reverse if leaves.size == 2
        leaves.map do |hinge, end_x|
          radius = end_x - hinge
          arc = 17.times.map do |i|
            angle = i * Math::PI / 32
            [hinge + radius * Math.cos(angle), lateral + sign * radius.abs * Math.sin(angle)]
          end
          [[hinge, lateral], arc]
        end
      end

      def runouts(door)
        x1, x2, = Openings.position(door)
        width = x2 - x1
        case type(door)
        when 'surface'
          direction(door).start_with?('start') ? [[x1, x1 - width]] : [[x2, x2 + width]]
        when 'split'
          [[x1, x1 - width / 2.0], [x2, x2 + width / 2.0]]
        else
          []
        end
      end

      def validate_runouts(openings, lower, upper)
        openings.each do |door|
          next unless door['kind'] == 'door' && door['motion'] && SURFACE.include?(type(door))

          _, _, bottom, top = Openings.position(door)
          runouts(door).each do |a, b|
            first, last = [a, b].minmax
            if first < lower || last > upper
              raise ArgumentError, '引き代が同じ壁区間に収まりません。位置か引く方向を変えてください。'
            end
            blocked = openings.any? do |other|
              next false if other.equal?(door)

              x1, x2, z1, z2 = Openings.position(other)
              first < x2 && x1 < last && bottom < z2 && z1 < top
            end
            if blocked
              raise ArgumentError, '引き代が別の開口と重なります。'
            end
          end
        end
      end

      def arrow(from, to, lateral)
        delta = to - from
        head = [35.0, delta.abs / 4.0].min
        back = to - (delta.negative? ? -head : head)
        [[[from, lateral], [to, lateral]], [[back, lateral + head * 0.4], [to, lateral], [back, lateral - head * 0.4]]]
      end

      def paths(door, left, right)
        paths = leaf_paths(door, left, right)
        return paths unless filled?(door)

        x1, x2, = Openings.position(door)
        width, y1, y2 = frame_dimensions(door, left, right)
        paths + [Openings.plan_rectangle(x1, x1 + width, y1, y2),
                 Openings.plan_rectangle(x2 - width, x2, y1, y2)]
      end

      def leaf_paths(door, left, right)
        id = type(door)
        return [] if id == 'empty'

        arcs = swings(door, left, right)
        return arcs.flat_map { |hinge, arc| [[hinge, arc.last], arc] } unless arcs.empty?

        x1, x2, = Openings.position(door)
        middle = (left + right) / 2.0
        width = x2 - x1
        if SURFACE.include?(id)
          lateral = side(door) == 'left' ? left + 16 : right - 16
          track = [[x1, lateral], [x2, lateral]]
          return [track, *runouts(door).flat_map { |a, b| arrow(a, b, lateral) }]
        end
        if id == 'bypass'
          gap = [(left - right).abs / 5.0, 16].min
          a, b = panes(door)
          return [[[a.first, middle + gap], [a.last, middle + gap]],
                  [[b.first, middle - gap], [b.last, middle - gap]]]
        end
        if id == 'fold'
          first, last = direction(door).start_with?('start') ? [x1, x2] : [x2, x1]
          sign = side(door) == 'left' ? 1 : -1
          fold = [[first, middle], [first + (last - first) * 0.32, middle + sign * width * 0.26],
                  [first + (last - first) * 0.64, middle]]
          return [[[x1, middle], [x2, middle]], fold]
        end
        panes(door).map do |a, b|
          inset = id == 'unequal' ? [4.0, (b - a) * 0.1].min : 0
          [[a + inset, middle], [b - inset, middle]]
        end
      end

      def filled?(door)
        door['kind'] == 'door' && door.key?('door_type') && type(door) != 'empty'
      end

      def leaf_boxes(door, left, right)
        x1, x2, _, top = Openings.position(door)
        trim, = frame_dimensions(door, left, right)
        half_depth = [(left - right).abs / 3.0, 18.0].min
        middle = (left + right) / 2.0
        panes(door).map.with_index do |(a, b), index|
          clearance = [3.0, (b - a) * 0.06, top * 0.05].min
          unless SURFACE.include?(type(door))
            a += trim if a == x1
            b -= trim if b == x2
          end
          y = case type(door)
              when 'surface', 'split' then side(door) == 'left' ? left + half_depth + 4 : right - half_depth - 4
              when 'bypass' then middle + half_depth * (index.zero? ? 1 : -1)
              else middle
              end
          depth = type(door) == 'bypass' ? half_depth / 2.0 : half_depth
          [[a + clearance, y - depth, clearance], [b - clearance, y + depth, top - trim - clearance]]
        end
      end

      def frame_dimensions(door, left, right)
        narrowest = panes(door).map { |a, b| b - a }.min
        trim = [32.0, narrowest * 0.25, door.fetch('height') * 0.12].min
        middle = (left + right) / 2.0
        half = [(left - right).abs / 2.0, 32.0].min
        [trim, middle - half, middle + half]
      end

      def section_sides(params, profile, door)
        origin, axis = Openings.segment(params.fetch('points'), door.fetch('segment'))
        profile.first(2).map { |point| Openings.projection(point, origin, [-axis[1], axis[0]]) }
      end

      def definition_for(model, door, left, right)
        offset = door.fetch('offset')
        boxes = leaf_boxes(door, left, right).map do |box|
          box.map { |x, y, z| [x - offset, y, z].map { |coordinate| coordinate.round(7) } }
        end
        trim, y1, y2 = frame_dimensions(door, left, right)
        width, height = door.values_at('width', 'height')
        signature = JSON.generate([DETAIL_VERSION, type(door), width, height, trim, y1, y2, boxes])
        existing = model.definitions.find { |item| item.get_attribute(API::DICT, 'door_signature') == signature }
        return existing if existing

        definition = model.definitions.add("SBR #{TYPES.fetch(type(door))}")
        definition.set_attribute(API::DICT, 'door_signature', signature)
        x1, x2 = [-width / 2.0, width / 2.0]
        frame = [[x1, 0], [x1 + trim, 0], [x1 + trim, height - trim], [x2 - trim, height - trim],
                 [x2 - trim, 0], [x2, 0], [x2, height], [x1, height]]
        add_prism(definition.entities, frame.map { |x, z| API.point(x, y1, z) }, Y_AXIS, y2 - y1)
        boxes.each do |(a, b, bottom), (c, d, top)|
          polygon = [[a, b], [c, b], [c, d], [a, d]].map { |x, y| API.point(x, y, bottom) }
          add_prism(definition.entities, polygon, Z_AXIS, top - bottom)
        end
        definition
      end

      def add_prism(entities, polygon, axis, distance)
        face = entities.add_face(polygon)
        raise ArgumentError, '建具の枠または扉を作成できませんでした。開口寸法を確認してください。' unless face

        face.reverse! if face.normal.dot(axis).negative?
        face.pushpull(distance.mm)
      end

      def write(group, params, profiles)
        points = params.fetch('points')
        params.fetch('openings', []).select { |door| filled?(door) }.each do |door|
          index = door.fetch('segment')
          origin, axis = Openings.segment(points, index)
          normal = [-axis[1], axis[0]]
          sides = section_sides(params, profiles.fetch(index), door)
          offset = door.fetch('offset')
          model = group.model
          definition = definition_for(model, door, *sides)
          anchor = API.point(origin[0] + axis[0] * offset, origin[1] + axis[1] * offset)
          transform = Geom::Transformation.axes(anchor, Geom::Vector3d.new(*axis, 0),
                                                Geom::Vector3d.new(*normal, 0), Z_AXIS)
          instance = group.entities.add_instance(definition, transform)
          instance.layer = model.layers[0]
          instance.set_attribute(API::DICT, 'opening_id', door.fetch('id'))
        end
      end
    end
  end
end
