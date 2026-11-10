# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class SectionPlacement
      API = SbrArchitecture
      Line = Struct.new(:axis, :offset, :start, :finish)
      MIN_DISTANCE = 1.0
      TOP_VIEW = '一般平面シーン、または上から見た平行投影で断面位置を指定してください。'

      def self.top_view?(view)
        camera = view.camera
        !camera.perspective? && camera.direction.samedirection?(Z_AXIS.reverse)
      end

      def self.line(start, cursor, along = nil)
        delta = cursor.zip(start).map { |value, origin| (value - origin).abs }
        along ||= delta[0] >= delta[1] ? 0 : 1
        return if delta[along] < MIN_DISTANCE

        axis = 1 - along
        finish = cursor.dup
        finish[axis] = start[axis]
        Line.new(axis, start[axis], start, finish)
      end

      def self.settings(line, cursor)
        distance = cursor[line.axis] - line.offset
        return if distance.abs < MIN_DISTANCE

        # The arrow points into the retained half, away from the camera side.
        { side: %w[x y][line.axis] + (distance.positive? ? '-' : '+'), offset: line.offset.round(6) }
      end

      def initialize(model, &finish)
        @model = model
        @finish = finish
        @input = Sketchup::InputPoint.new
      end

      def activate
        prompt
        @model.active_view.invalidate
      end

      def deactivate(view)
        view.invalidate
        complete(nil)
      end

      def resume(view)
        prompt
        view.invalidate
      end

      def cancel
        @model.select_tool(nil) if @finish
      end

      def complete(data)
        callback, @finish = @finish, nil
        @model.select_tool(nil) if data
        callback&.call(data)
      end

      def prompt
        message = if @line
                    '③ 矢印を向ける側をクリック。Escで終点指定に戻る。'
                  elsif @start
                    lock = %w[X Y][@along] if @along
                    lock ? "② #{lock}軸固定。断面線の終点をクリック。" :
                      '② 断面線の終点をクリック。右キーでX、左キーでYに固定。'
                  else
                    '① 平面上で断面線の始点をクリック。Escで終了。'
                  end
        Sketchup.set_status_text(message, SB_PROMPT)
      end

      def onMouseMove(_flags, x, y, view)
        @mouse = [x, y]
        @cursor = nil
        unless self.class.top_view?(view)
          Sketchup.set_status_text(TOP_VIEW, SB_PROMPT)
          view.invalidate
          return
        end

        @z = view.camera.target.z
        unless @line
          @input.pick(view, x, y)
          if @input.valid? && @input.degrees_of_freedom < 3
            @cursor = xy(@input.position)
            view.tooltip = @input.tooltip
          end
        end
        point = Geom.intersect_line_plane(view.pickray(x, y), [Geom::Point3d.new(0, 0, @z), Z_AXIS]) unless @cursor
        @cursor ||= xy(point) if point
        prompt
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        onMouseMove(flags, x, y, view)
        return unless @cursor

        if @line
          data = self.class.settings(@line, @cursor)
          return unless data

          complete(data)
        elsif @start
          @line = self.class.line(@start, @cursor, @along)
        else
          @start = @cursor
        end
        prompt if @finish
        view.invalidate
      end

      def onKeyDown(key, repeat, flags, view)
        axis = API.arrow_axis(key)
        return false unless axis && @start && !@line
        return true if axis == :z || repeat > 1

        along = axis == :x ? 0 : 1
        @along = @along == along ? nil : along
        onMouseMove(flags, *@mouse, view) if @mouse
        true
      end

      def onCancel(reason, view)
        return unless reason.zero?

        if @line
          @line = nil
        elsif @start
          @start = @along = nil
        else
          cancel
        end
        @cursor = nil
        prompt if @finish
        view.invalidate
      end

      def xy(point)
        [point.x.to_mm, point.y.to_mm]
      end

      def screen(view, coordinates)
        x, y = coordinates
        view.screen_coords(Geom::Point3d.new(x.mm, y.mm, @z))
      end

      def draw(view)
        return unless @cursor

        view.drawing_color = Sketchup::Color.new(0, 157, 163)
        view.line_width = 2
        line = @line || (@start && self.class.line(@start, @cursor, @along))
        unless line
          at = screen(view, @start || @cursor)
          view.draw2d(GL_LINES, [pixel(at.x - 5, at.y), pixel(at.x + 5, at.y),
                                 pixel(at.x, at.y - 5), pixel(at.x, at.y + 5)])
          return
        end

        endpoints = [line.start, line.finish].map { |point| screen(view, point) }
        view.draw2d(GL_LINES, endpoints)
        if @line && self.class.settings(line, @cursor)
          offset = line.start.dup
          offset[line.axis] += @cursor[line.axis] > line.offset ? 1000 : -1000
          head = screen(view, offset)
          dx, dy = head.x - endpoints.first.x, head.y - endpoints.first.y
          length = Math.hypot(dx, dy)
          endpoints.each { |point| arrow(view, point, dx / length, dy / length) } if length.positive?
        end
      end

      def pixel(x, y)
        Geom::Point3d.new(x, y, 0)
      end

      def arrow(view, at, dx, dy)
        tip = pixel(at.x + dx * 25, at.y + dy * 25)
        view.draw2d(GL_LINES, [at, tip,
                               tip, pixel(at.x + dx * 17 - dy * 5, at.y + dy * 17 + dx * 5),
                               tip, pixel(at.x + dx * 17 + dy * 5, at.y + dy * 17 - dx * 5)])
      end
    end
  end
end
