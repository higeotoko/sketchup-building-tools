# frozen_string_literal: true

require_relative 'roof'

require 'securerandom'
require_relative 'doors'
require_relative 'sashes'

module Higeotoko
  module SbrArchitecture
    module Openings
      API = SbrArchitecture
      TYPES = { 'window' => '窓開口', 'door' => '扉開口' }.freeze
      WINDOW_TYPES = {
        'sliding' => '引違い', 'single_slide' => '片引き', 'fixed' => 'FIX',
        'casement' => '片開き', 'double_casement' => '両開き',
        'vertical_awning' => '縦すべり出し', 'horizontal_awning' => '横すべり出し',
        'double_hung' => '上げ下げ', 'hopper' => '内倒し', 'outward_hopper' => '外倒し'
      }.freeze
      HANDED_WINDOWS = %w[single_slide casement vertical_awning].freeze
      WINDOW_MOUNTS = { 'flush' => '外壁面合わせ', 'inset' => 'インセット', 'outset' => 'アウトセット' }.freeze
      EXTERIOR_SIDES = { 'auto' => '自動（閉じた壁の外側）', 'right' => '壁芯の右側', 'left' => '壁芯の左側' }.freeze
      ANCHORS = { 'center' => '中心', 'start' => '区間始点側の端', 'end' => '区間終点側の端' }.freeze
      DOOR_SWINGS = {
        'none' => '開口のみ',
        'start_left' => '区間始点側で吊る · 壁芯の左へ開く',
        'start_right' => '区間始点側で吊る · 壁芯の右へ開く',
        'end_left' => '区間終点側で吊る · 壁芯の左へ開く',
        'end_right' => '区間終点側で吊る · 壁芯の右へ開く'
      }.freeze
      module_function

      def fields(kind)
        kind == 'window' ? [1650, 1100, 900] : [800, 2000, 0]
      end

      def parameters(kind, values)
        TYPES.fetch(kind)
        sill = kind == 'door' ? 0.0 : Layout.mm(values['sill'], '腰高')
        raise ArgumentError, '腰高は0 mm以上にしてください。' if sill.negative? || (sill.positive? && sill < Layout::MIN_MM)

        result = {
          'kind' => kind,
          'width' => Layout.mm(values['width'], '開口幅', positive: true),
          'height' => Layout.mm(values['height'], '開口高さ', positive: true),
          'sill' => sill,
          'mark' => values['mark'].to_s.strip
        }
        if kind == 'window'
          type = values.fetch('window_type', 'sliding')
          raise ArgumentError, '窓の形式を選んでください。' unless WINDOW_TYPES.key?(type)

          mode = values.fetch('mount_mode', 'flush')
          side = values.fetch('exterior_side', 'auto')
          unless WINDOW_MOUNTS.key?(mode) && EXTERIOR_SIDES.key?(side)
            raise ArgumentError, '窓の取付位置と外側を指定してください。'
          end
          offset = mode == 'flush' ? 0.0 : Layout.mm(values['mount_offset'], '外壁面からの距離', positive: true)
          result.merge!('window_type' => type, 'mounting' => { 'mode' => mode, 'side' => side, 'offset' => offset })
          if HANDED_WINDOWS.include?(type)
            hinge = values.fetch('hinge', 'start')
            raise ArgumentError, '窓の可動側を指定してください。' unless %w[start end].include?(hinge)

            result['hinge'] = hinge
          end
        else
          result.merge!(Doors.settings(values, result.fetch('width')))
        end
        if values.key?('anchor')
          anchor = values.fetch('anchor')
          raise ArgumentError, '開口の基準点を選んでください。' unless ANCHORS.key?(anchor)

          result['anchor'] = anchor
        end
        result
      end

      def door_swing(opening)
        swing = opening['swing']
        if opening['kind'] == 'door' && Doors::HINGED.include?(Doors.type(opening)) && swing != 'none' && DOOR_SWINGS.key?(swing)
          swing.split('_')
        end
      end

      def window_type(opening)
        return opening['window_type'] if WINDOW_TYPES.key?(opening['window_type'])

        opening.dig('sash', 'product_id').to_s.include?('-fix-') ? 'fixed' : 'sliding'
      end

      def window_mount(opening)
        return opening['mounting'] if opening['mounting']

        sash = opening['sash'] || {}
        inset = sash.fetch('inset', 0)
        { 'mode' => inset.positive? ? 'inset' : 'flush', 'side' => sash.fetch('side', 'auto'), 'offset' => inset }
      end

      def window_exterior(opening, points, outside: nil)
        side = window_mount(opening).fetch('side')
        return side unless side == 'auto'

        outside || Layout.outside_side(points)
      end

      def window_anchor(opening, left, right, points, outside: nil)
        mount = window_mount(opening)
        exterior = window_exterior(opening, points, outside: outside)
        sign = exterior == 'left' ? 1 : -1
        offset = mount.fetch('offset')
        offset = -offset if mount['mode'] == 'inset'
        [exterior == 'left' ? left + sign * offset : right + sign * offset, sign]
      end

      def window_paths(opening, left, right, points, outside: nil)
        x1, x2, = position(opening)
        # Keep an unedited legacy opening centred until a mounting is assigned.
        lateral, sign = if opening['mounting'] || opening['sash']
                          window_anchor(opening, left, right, points, outside: outside)
                        else
                          [(left + right) / 2.0, -1]
                        end
        width = x2 - x1
        gap = [18.0, width * 0.15].min
        case window_type(opening)
        when 'sliding', 'single_slide'
          lateral += sign * Sashes::SLIDING_DEPTH / 2.0 unless opening['mounting'] || opening['sash']
          sliding_window_paths(opening, x1, x2, lateral, sign)
        when 'vertical_awning', 'casement'
          hinge, other = opening.fetch('hinge', 'start') == 'start' ? [x1, x2] : [x2, x1]
          reach = window_type(opening) == 'casement' ? 0.45 : 0.28
          [[[x1, lateral], [x2, lateral]], [[hinge, lateral], [hinge + (other - hinge) * 0.88, lateral + sign * width * reach]]]
        when 'double_casement'
          [[[x1, lateral], [x2, lateral]],
           [[x1, lateral], [x1 + width * 0.4, lateral + sign * width * 0.23]],
           [[x2, lateral], [x2 - width * 0.4, lateral + sign * width * 0.23]]]
        when 'double_hung'
          [[[x1, lateral], [x2, lateral]], [[x1, lateral - sign * gap], [x2, lateral - sign * gap]]]
        else
          [[[x1, lateral], [x2, lateral]]]
        end
      end

      def plan_rectangle(x1, x2, y1, y2)
        [[x1, y1], [x2, y1], [x2, y2], [x1, y2], [x1, y1]]
      end

      def sliding_window_paths(opening, x1, x2, lateral, sign)
        width, height = opening.values_at('width', 'height')
        trim = Sashes.frame_width(width, height)
        depth = Sashes::SLIDING_DEPTH
        inner = lateral - sign * depth
        paths = [plan_rectangle(x1, x1 + trim, lateral, inner),
                 plan_rectangle(x2 - trim, x2, lateral, inner)]
        Sashes.sliding_parts(width, height).each_with_index do |((a, b), (front, back), stile), index|
          run = ->(x) { sign.positive? ? x2 - x : x1 + x }
          y1, y2 = [front, back].map { |y| lateral - sign * y }
          paths << plan_rectangle(run.call(a), run.call(b), y1, y2)
          # Show the meeting stile on each track.
          meeting = run.call(index.zero? ? b - stile : a + stile)
          paths << [[meeting, y1], [meeting, y2]]
        end
        if window_type(opening) == 'single_slide'
          center = (x1 + x2) / 2.0
          movable = opening.fetch('hinge', 'start') == 'start' ? x1 : x2
          paths.concat(Doors.arrow((movable + center) / 2.0, center, lateral + sign * 24))
        end
        paths
      end

      def direction_at(along, across)
        return if along.abs < 0.5 || across.abs < 0.5

        "#{along.negative? ? 'start' : 'end'}_#{across.positive? ? 'left' : 'right'}"
      end

      def swing_path(opening, left, right)
        Doors.swings(opening, left, right).first if opening['kind'] == 'door'
      end

      def symbol_paths(opening, left, right, points, outside: nil)
        return window_paths(opening, left, right, points, outside: outside) if opening['kind'] == 'window'

        Doors.paths(opening, left, right)
      end

      def label(opening)
        opening['kind'] == 'window' ? WINDOW_TYPES.fetch(window_type(opening)) : Doors::TYPES.fetch(Doors.type(opening))
      end

      def update_generic_fills(model)
        model.entities.grep(Sketchup::Group).each do |wall|
          next unless Follow.kind(wall) == 'wall' && !wall.locked?

          params = Follow.parameters(wall)
          openings = params.fetch('openings', []).to_h { |opening| [opening.fetch('id'), opening] }
          profiles = nil
          wall.entities.grep(Sketchup::ComponentInstance).each do |part|
            opening = openings[part.get_attribute(API::DICT, 'opening_id')]
            next unless opening && !part.locked?

            definition = part.definition
            replacement = if Doors.filled?(opening) && definition.get_attribute(API::DICT, 'door_signature')
                            profiles ||= API.wall_profiles(params)
                            sides = Doors.section_sides(params, profiles.fetch(opening.fetch('segment')), opening)
                            Doors.definition_for(model, opening, *sides)
                          elsif opening['kind'] == 'window' && !opening['sash'] &&
                                Sashes::SLIDING_TYPES.include?(window_type(opening)) &&
                                definition.get_attribute(API::DICT, 'window_signature')
                            Sashes.generic_definition(model, opening)
                          end
            next unless replacement && replacement != definition

            part.definition = replacement
          end
        end
      end

      def position(opening)
        x = opening.fetch('offset')
        z = opening.fetch('sill')
        half_width = opening.fetch('width') / 2.0
        [x - half_width, x + half_width, z, z + opening.fetch('height')]
      end

      def segment(points, index)
        a, b = points.fetch(index), points.fetch(index + 1)
        x, y = b.zip(a).map { |ending, start| ending - start }
        length = Math.hypot(x, y)
        [a, [x / length, y / length]]
      end

      def projection(point, origin, axis)
        (point[0] - origin[0]) * axis[0] + (point[1] - origin[1]) * axis[1]
      end

      def wall_point(origin, axis, offset, lateral)
        [origin[0] + axis[0] * offset - axis[1] * lateral,
         origin[1] + axis[1] * offset + axis[0] * lateral]
      end

      def validate(params, profiles)
        grouped = params.fetch('openings', []).group_by { |opening| opening.fetch('segment') }
        planes = Roof.roof_planes(params)
        grouped.each do |index, openings|
          raise ArgumentError, '開口のある壁区間が見つかりません。' unless index.between?(0, profiles.size - 1)

          origin, axis = segment(params.fetch('points'), index)
          left_a, right_a, right_b, left_b = profiles.fetch(index).map { |p| projection(p, origin, axis) }
          lower, upper = [left_a, right_a].max, [left_b, right_b].min
          lateral = profiles.fetch(index).first(2).map { |point| projection(point, origin, [-axis[1], axis[0]]) } if planes
          openings.each do |opening|
            x1, x2, z1, z2 = position(opening)
            height = if planes
                       [x1, x2].product(lateral).map { |x, offset| Roof.roof_height(planes, wall_point(origin, axis, x, offset)) }.min
                     else
                       params.fetch('height')
                     end
            if x1 - lower < Layout::MIN_MM || upper - x2 < Layout::MIN_MM ||
               z1.negative? || height - z2 < Layout::MIN_MM
              raise ArgumentError, '開口が壁の端または天端にかかります。位置・寸法を調整してください。'
            end
            mount = window_mount(opening) if opening['mounting'] || opening['sash']
            if mount && mount['mode'] == 'inset' && mount.fetch('offset') >= params.fetch('thickness')
              raise ArgumentError, '窓のインセットは壁厚より小さくしてください。'
            end
          end
          openings.combination(2).each do |first, second|
            ax, bx, az, bz = position(first)
            cx, dx, cz, dz = position(second)
            next if bx + Layout::MIN_MM <= cx || dx + Layout::MIN_MM <= ax ||
                    bz + Layout::MIN_MM <= cz || dz + Layout::MIN_MM <= az

            raise ArgumentError, '開口同士が重なるか、近すぎます。'
          end
          Doors.validate_runouts(openings, lower, upper)
        end
        grouped
      end

      def side_loop(a, b, top, doors, at)
        [at.call(a, 0), *doors.flat_map { |x1, x2, _, z| [[x1, 0], [x1, z], [x2, z], [x2, 0]].map { |x, h| at.call(x, h) } },
         at.call(b, 0), *top]
      end

      def write_segment(group, params, profile, index, openings)
        origin, axis = segment(params.fetch('points'), index)
        xy = profile.map { |p| [projection(p, origin, axis), projection(p, origin, [-axis[1], axis[0]])] }
        left_a, right_a, right_b, left_b = xy
        height = params.fetch('height')
        planes = Roof.roof_planes(params)
        top = ->(point) { API.point(*point, planes ? Roof.roof_height(planes, point) : height) }
        top_edge = lambda do |first, last|
          a, b = profile.values_at(first, last)
          points = planes ? Roof.roof_edge(planes, a, b) : [a, b]
          points.map(&top)
        end
        at = lambda do |offset, lateral, z|
          API.point(*wall_point(origin, axis, offset, lateral), z)
        end
        left = ->(x, z) { at.call(x, left_a[1], z) }
        right = ->(x, z) { at.call(x, right_a[1], z) }
        doors, windows = openings.map { |opening| position(opening) }.sort_by(&:first).partition { |_, _, z, _| z.zero? }
        group.entities.build do |builder|
          [[right_a, right_b, right, [2, 1], false], [left_a, left_b, left, [3, 0], true]].each do |a, b, side, edge, reverse|
            outer = side_loop(a[0], b[0], top_edge.call(*edge), doors, side)
            holes = windows.map do |x1, x2, z1, z2|
              [[x1, z1], [x1, z2], [x2, z2], [x2, z1]].map { |x, z| side.call(x, z) }
            end
            outer, holes = outer.reverse, holes.map(&:reverse) if reverse
            builder.add_face(outer, holes: holes)
          end
          caps = planes ? Roof.roof_caps(planes, profile) : [profile]
          caps.each { |cap| builder.add_face(cap.map(&top)) }
          builder.add_face([left.call(left_a[0], 0), right.call(right_a[0], 0), *top_edge.call(1, 0)])
          builder.add_face([right.call(right_b[0], 0), left.call(left_b[0], 0), *top_edge.call(3, 2)])
          starts = [[left_a[0], right_a[0]], *doors.map { |_, x2, _, _| [x2, x2] }]
          ends = [*doors.map { |x1, _, _, _| [x1, x1] }, [left_b[0], right_b[0]]]
          starts.zip(ends).each do |(a, b), (c, d)|
            builder.add_face([left.call(a, 0), left.call(c, 0), right.call(d, 0), right.call(b, 0)])
          end
          (doors + windows).each do |x1, x2, z1, z2|
            builder.add_face([right.call(x1, z1), left.call(x1, z1), left.call(x1, z2), right.call(x1, z2)])
            builder.add_face([left.call(x2, z1), right.call(x2, z1), right.call(x2, z2), left.call(x2, z2)])
            builder.add_face([left.call(x1, z2), left.call(x2, z2), right.call(x2, z2), right.call(x1, z2)])
            if z1.positive?
              builder.add_face([right.call(x1, z1), right.call(x2, z1), left.call(x2, z1), left.call(x1, z1)])
            end
          end
        end
        raise ArgumentError, '開口付きの壁をソリッドとして作成できませんでした。' unless group.manifold? && group.volume.positive?

        group.entities.each { |entity| entity.layer = group.model.layers[0] }
      end

      class Placement
        def active?
          @active
        end

        def initialize(model, params, plan: nil)
          @model, @params, @plan = model, params, plan
          @input = Sketchup::InputPoint.new
        end

        def activate
          @active = true
          if @choosing_direction
            message = if window?
                        Openings.window_type(@params) == 'single_slide' ? '動かす障子の側をクリック。' : '吊り元にしたい端をクリック。'
                      else
                        case Doors.type(@params)
                        when 'surface' then '戸を引く方向と、戸を付ける壁面側をクリック。'
                        when 'split' then '戸を付ける壁面側をクリック。'
                        when 'double' then '扉を開く壁面側をクリック。'
                        when 'fold' then '折りたたむ端と、折れる壁面側をクリック。'
                        else '吊り元側かつ開く側をクリック。'
                        end
                      end
            message += ' Escで位置を戻す。'
            Sketchup.set_status_text(message, SB_PROMPT)
            return
          end

          target = @plan ? '平面の壁線上' : '壁面上'
          lock = @axis_lock && " #{@axis_lock.to_s.upcase}軸固定。"
          anchor = ANCHORS.fetch(@params.fetch('anchor', 'center'))
          Sketchup.set_status_text("#{Openings.label(@params)}の#{anchor}を#{target}でクリック。#{lock}Escで終了。", SB_PROMPT)
        end

        def resume(view)
          activate
          view.invalidate
        end

        def update_settings(params, plan)
          @settings = [params, plan]
          reset_candidate unless @choosing_direction
        end

        def reset_candidate
          @params, @plan = @settings if @settings
          @settings = @candidate = @plan_hit = @direction = @choosing_direction = nil
          @axis_lock = nil if @axis_lock == :z
          activate
        end

        def onMouseMove(_flags, x, y, view)
          @mouse = [x, y]
          if @choosing_direction
            @direction = pick_direction(view, x, y)
            @valid = valid_direction?
            return
          end
          return if @axis_lock == :z && @candidate

          @candidate = nil
          @valid = false
          if @plan
            @plan_hit = @plan.hit(view, x, y, axis: @axis_lock)
            return unless @plan_hit

            segment = @plan_hit.segment
            prepare(segment.wall, segment.params, segment.index, @plan_hit.offset)
            return
          end

          @input.pick(view, x, y)
          path = @input.instance_path&.to_a if @input.valid? && @input.face
          wall = path&.first
          if wall.is_a?(Sketchup::Group) && !wall.locked? && wall.get_attribute(API::DICT, 'kind') == 'wall' &&
             !path[1].is_a?(Sketchup::ComponentInstance)
            params = JSON.parse(wall.get_attribute(API::DICT, 'parameters'))
            index = path[1].is_a?(Sketchup::Group) ? wall.entities.grep(Sketchup::Group).index(path[1]) : 0
            local = @input.position.transform(wall.transformation.inverse).to_a.map(&:to_mm)
            origin, axis = Openings.segment(params.fetch('points'), index)
            if @axis_lock
              a = API.point(*origin).transform(wall.transformation)
              b = API.point(origin[0] + axis[0] * 100, origin[1] + axis[1] * 100).transform(wall.transformation)
              return unless (b - a).parallel?(@axis_lock == :x ? X_AXIS : Y_AXIS)
            end
            offset = Openings.projection(local, origin, axis).round(1)
            prepare(wall, params, index, offset)
          end
        rescue ArgumentError, IndexError, KeyError
          @valid = false
        ensure
          view.invalidate
        end

        def onKeyDown(key, repeat, flags, view)
          axis = API.arrow_axis(key)
          return false unless axis
          return true if repeat > 1 || @choosing_direction
          return true if axis == :z && !@valid

          @axis_lock = @axis_lock == axis ? nil : axis
          onMouseMove(flags, *@mouse, view) if @mouse
          activate
          true
        end

        def prepare(wall, params, index, offset)
          half = @params.fetch('width') / 2.0
          offset += { 'start' => half, 'end' => -half }.fetch(@params['anchor'], 0)
          opening = @params.reject { |key, _| key == 'anchor' }.merge('segment' => index, 'offset' => offset)
          profiles = API.wall_profiles(params)
          pending = params.merge('openings' => params.fetch('openings', []) + [opening])
          @candidate = [wall, params, pending, opening, profiles.fetch(index)]
          Openings.validate(pending, profiles)
          @plan&.validate_opening!(@plan_hit, opening)
          @valid = true
        end

        def direction_key
          window? ? ('hinge' if HANDED_WINDOWS.include?(Openings.window_type(@params))) : Doors.direction_key(@params)
        end

        def candidate_with_direction(direction)
          wall, previous, pending, opening, profile = @candidate
          return @candidate unless direction

          opening = opening.merge(direction_key => direction)
          [wall, previous, pending.merge('openings' => pending.fetch('openings')[0...-1] + [opening]), opening, profile]
        end

        def valid_direction?
          return true unless @direction && !window? && Doors::SURFACE.include?(Doors.type(@params))

          _, previous, pending = candidate_with_direction(@direction)
          Openings.validate(pending, API.wall_profiles(previous))
          true
        rescue ArgumentError
          false
        end

        def onLButtonDown(flags, x, y, view)
          onMouseMove(flags, x, y, view)
          return finish(@direction, view) if @choosing_direction && @direction
          return if @choosing_direction
          return unless @candidate

          if @valid && direction_key
            @axis_lock = nil if @axis_lock == :z
            @choosing_direction = true
            activate
            view.invalidate
          else
            finish(nil, view)
          end
        end

        def onReturn(view)
          return unless @choosing_direction

          direction = window? ? 'start' : Doors.direction(@params)
          finish(@direction || direction, view)
        end

        def window?
          @params['kind'] == 'window'
        end

        def finish(direction, view)
          API.report_errors do
            API.top_level!(@model)
            if @plan && !@plan.current?(view)
              raise ArgumentError, '平面が切り替わりました。建具ツールを選び直してください。'
            end
            wall, previous, pending, opening = candidate_with_direction(direction)
            unless wall.valid? && !wall.locked? && Follow.parameters(wall) == previous
              raise ArgumentError, '壁の設定が変わりました。Escで戻り、開口位置を選び直してください。'
            end

            Openings.validate(pending, API.wall_profiles(previous))
            @plan&.validate_opening!(@plan_hit, opening)
            opening['id'] = SecureRandom.uuid
            API.regenerate(wall, pending, refresh_plan: !!@plan)
            @model.selection.clear
            @model.selection.add(wall)
            reset_candidate
            @plan = @plan.refresh if @plan
            view.invalidate
          end
        end

        def frame
          wall, params, _, opening, profile = @candidate
          origin, axis = Openings.segment(params.fetch('points'), opening.fetch('segment'))
          perpendicular = [-axis[1], axis[0]]
          at = lambda do |x, y, z|
            API.point(origin[0] + axis[0] * x + perpendicular[0] * y,
                      origin[1] + axis[1] * x + perpendicular[1] * y, z).transform(wall.transformation)
          end
          sides = profile.first(2).map { |p| Openings.projection(p, origin, perpendicular) }
          [at, sides, origin, axis, perpendicular]
        end

        def pick_direction(view, x, y)
          wall, _, _, opening = @candidate
          return unless wall.valid?

          at, sides, origin, axis, perpendicular = frame
          z = @plan_hit ? @plan_hit.segment.cut_height : opening.fetch('sill') + 1
          offset = opening.fetch('offset')
          middle = sides.sum / 2.0
          center = at.call(offset, middle, z)
          screen = view.screen_coords(center)
          return if Math.hypot(x - screen.x, y - screen.y) < 5

          normal = (at.call(offset + 100, middle, z) - center).cross(at.call(offset, middle + 100, z) - center)
          point = Geom.intersect_line_plane(view.pickray(x, y), [center, normal])
          return unless point

          local = point.transform(wall.transformation.inverse).to_a.map(&:to_mm)
          along = Openings.projection(local, origin, axis) - offset
          return (along.negative? ? 'start' : 'end') if window? && along.abs >= 0.5
          return if window?

          across = Openings.projection(local, origin, perpendicular) - middle
          along = -1 if %w[double split].include?(Doors.type(@params))
          Openings.direction_at(along, across)
        end

        def draw(view)
          return unless @candidate

          wall, params, _, opening = candidate_with_direction(@choosing_direction ? @direction : nil)
          return unless wall.valid?

          view.drawing_color = @valid ? Sketchup::Color.new(0, 135, 121) : Sketchup::Color.new(205, 63, 47)
          view.line_width = 3
          return @plan.draw(view, @plan_hit, opening, fixed: !!@choosing_direction) if @plan

          x1, x2, z1, z2 = Openings.position(opening)
          at, sides = frame
          sides.each do |y|
            loop = [[x1, z1], [x2, z1], [x2, z2], [x1, z2]].map { |x, z| at.call(x, y, z) }
            view.draw(GL_LINE_LOOP, loop)
          end
          Openings.symbol_paths(opening, *sides, params.fetch('points'), outside: Layout.wall_outside(params)).each do |path|
            view.draw(GL_LINE_STRIP, path.map { |x, y| at.call(x, y, z1 + 1) })
          end
        end

        def getExtents
          @model.bounds
        end

        def onCancel(reason, view)
          if @choosing_direction
            reset_candidate
            view.invalidate
          elsif reason.zero? && @axis_lock
            @axis_lock = nil
            onMouseMove(0, *@mouse, view) if @mouse
            activate
          elsif reason.zero?
            @model.select_tool(nil)
          end
        end

        def deactivate(view)
          @active = false
          view.invalidate
        end
      end
    end
  end
end
