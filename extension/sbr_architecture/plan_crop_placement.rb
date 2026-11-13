# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class PlanCropPlacement
      TOP_VIEW = '一般平面シーン、または上から見た平行投影で範囲を指定してください。'

      def initialize(model, &finish)
        @model = model
        @finish = finish
        @input = Sketchup::InputPoint.new
      end

      def activate
        prompt
      end

      def resume(view)
        prompt
        view.invalidate
      end

      def deactivate(view)
        view.invalidate
        complete(nil)
      end

      def cancel
        @model.select_tool(nil) if @finish
      end

      def onCancel(reason, _view)
        cancel if reason.zero?
      end

      def onMouseMove(_flags, x, y, view)
        @cursor = nil
        if SectionPlacement.top_view?(view)
          @z = view.camera.target.z
          @input.pick(view, x, y)
          if @input.valid? && @input.degrees_of_freedom < 3
            point = @input.position
            view.tooltip = @input.tooltip
          else
            point = Geom.intersect_line_plane(view.pickray(x, y), [Geom::Point3d.new(0, 0, @z), Z_AXIS])
          end
          @cursor = [point.x.to_mm.round(3), point.y.to_mm.round(3)] if point
          prompt
        else
          Sketchup.set_status_text(TOP_VIEW, SB_PROMPT)
        end
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        onMouseMove(flags, x, y, view)
        return unless @cursor

        if @first
          crop = PlanCrop.rectangle(@first, @cursor)
          return unless PlanCrop.extent(crop).all? { |span| span >= PlanCrop::MIN_SPAN }

          complete(crop)
        else
          @first = @cursor
          prompt
        end
      end

      def draw(view)
        return unless @first && @cursor

        x1, y1, x2, y2 = PlanCrop.rectangle(@first, @cursor)
        points = [[x1, y1], [x2, y1], [x2, y2], [x1, y2]].map do |x, y|
          view.screen_coords(Geom::Point3d.new(x.mm, y.mm, @z))
        end
        view.drawing_color = Sketchup::Color.new(0, 157, 163)
        view.line_width = 2
        view.draw2d(GL_LINE_LOOP, points)
      end

      private

      def prompt
        point = @first ? '② 対角のもう一方' : '① 範囲の最初の角'
        Sketchup.set_status_text("#{point}をクリック。Escで中止。", SB_PROMPT)
      end

      def complete(crop)
        callback, @finish = @finish, nil
        @model.select_tool(nil) if crop
        callback&.call(crop)
      end
    end
  end
end
