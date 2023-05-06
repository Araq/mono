import base, ./component, ./el, ./tmpl


test "el html":
  let html = el"ul.c1":
    for text in @["t1"]:
      el"li.c2":
        it.attr("class", "c3") # Feature: setting attribute using `it`
        it.text(text)
        it.on_click(proc (e: auto) = discard)

  check html.to_html == """
    <ul class="c1">
      <li class="c2 c3" on_click="true">t1</li>
    </ul>
  """.dedent.trim


test "el component":
  type Panel = ref object of Component
    color:   string
  proc render(self: Panel, content: seq[El]): El = # Feature: render can have optional arg `content`
    el"panel .{self.color}":
      it.add content

  type Button = ref object of Component
    color: string
  proc render(self: Button): El =
    el"button .{self.color}"

  type App = ref object of Component
  proc render(self: App): El =
    el"app":
      el(Panel, (color: "blue")):
        el(Button, (color: "blue"))

  let root_el = el(App, (color: "blue"))
  check root_el.to_html == """
    <app>
      <panel class="blue">
        <button class="blue"></button>
      </panel>
    </app>
  """.dedent.trim


test "el proc component":
  proc Button(color: string): El =
    el"button .{color}"

  # Feature: proc component can have optional argument `content`
  proc Panel(color: string, size = "small", content: seq[El]): El =
    el"panel .{color} .{size}":
      it.add content

  type LRLayout = ref object of Component
    left*, right*: seq[El]
  proc render(self: LRLayout): El =
    el"layout":
      if not self.left.is_empty:
        el"left":
          it.add self.left
      if not self.right.is_empty:
        el"right":
          it.add self.right

  type App = ref object of Component
  proc render(self: App): El =
    el"app":
      el(LRLayout, ()):
        # Feature: if there are many slots, like `panel.left/right`, it could be set explicitly using `it`
        it.left = els:
          el(Panel, (color: "blue")):
            el(Button, (color: "blue"))

  let root_el = el(App, (color: "blue"))
  check root_el.to_html == """
    <app>
      <layout>
        <left>
          <panel class="blue small">
            <button class="blue"></button>
          </panel>
        </left>
      </layout>
    </app>
  """.dedent.trim


test "el stateful component":
  type Panel = ref object of Component
    color:   string

  proc render(self: Panel, content: seq[El]): El =
    el"panel .{self.color}":
      it.add content

  type Button = ref object of Component
    color: string
  proc render(self: Button): El =
    el"button .{self.color}"

  type App = ref object of Component
  proc render(self: App): El =
    el"app":
      self.el(Panel, "panel", (color: "blue")):
        el(Button, (color: "blue"))

  let root_el = el(App, (color: "blue"))
  check root_el.to_html == """
    <app>
      <panel class="blue">
        <button class="blue"></button>
      </panel>
    </app>
  """.dedent.trim