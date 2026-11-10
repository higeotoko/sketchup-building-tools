"use strict";

const byId = id => document.getElementById(id);
const fieldArea = byId("properties");
let project, activeTool = "wall", activeSystem, activeForm;
let editing = false;

function labeled(text, control, wide = false) {
  const label = document.createElement("label");
  label.classList.toggle("wide", wide);
  label.append(text, control);
  return label;
}

function select(options, selected) {
  const control = document.createElement("select");
  control.replaceChildren(...options.map(([id, name]) => new Option(name, id)));
  if (options.some(([id]) => id === selected)) control.value = selected;
  return control;
}

function optionButton(label, key, activate, icon) {
  const button = document.createElement("button");
  button.type = "button";
  button.dataset.value = key;
  if (icon) {
    const image = document.createElement("img");
    image.src = icon + ".svg";
    image.alt = "";
    button.append(image);
  }
  button.append(label);
  button.addEventListener("click", () => activate(key));
  return button;
}

function markActive() {
  for (const [id, active] of [["systems", activeSystem], ["tools", activeTool]]) {
    for (const button of byId(id).children) button.setAttribute("aria-pressed", button.dataset.value === active);
  }
}

function values() {
  return Object.fromEntries([...fieldArea.querySelectorAll("[name]")].map(input => [input.name, input.value]));
}

function saveDefaults() {
  if (!project || !activeForm || editing) return;
  if (!byId("form").checkValidity()) {
    PaletteUI.message({text: "入力値を確認してください。作図には最後に反映した設定を使います。", error: true});
    return;
  }
  sketchup.toolDefaults(JSON.stringify({token: project.token, kind: activeForm.kind, system: activeForm.system,
                                        values: values(), layers: layerValues()}));
}

function timberFields(field) {
  const role = select(field.options.map(([id, name]) => [id, name]), field.role);
  const sections = select([], "");
  role.name = "role";
  sections.name = field.key;
  const update = preferred => {
    const [, , defaultSection, options] = field.options.find(entry => entry[0] === role.value);
    sections.replaceChildren(...options.map(([id, name]) => new Option(name + " mm", id)));
    sections.value = options.some(([id]) => id === preferred) ? preferred : defaultSection;
  };
  role.addEventListener("change", () => update());
  update(field.value);
  fieldArea.append(labeled("役割", role), labeled("断面 (mm)", sections));
}

const familyNames = {H:"H形鋼", BOX:"角形鋼管", PIPE:"丸鋼管", ANGLE:"山形鋼", CHANNEL:"溝形鋼",
                     I:"I形鋼", C:"軽量形鋼", FB:"平鋼", CT:"CT形鋼", HB:"六角鋼", SB:"角鋼", RB:"丸鋼"};

function steelFields(field) {
  const families = [...new Set(field.options.map(option => option[2]))];
  const selected = field.value;
  const family = select([["", "全種類"], ...families.map(id => [id, familyNames[id] ?? id])],
                        field.options.find(([id]) => id === selected)?.[2] ?? "");
  const search = document.createElement("input");
  search.type = "search";
  search.placeholder = "例 300×150";
  const sections = select([], "");
  sections.name = field.key;
  sections.required = true;
  const normalize = value => value.toLowerCase().replace(/[×ｘ]/g, "x").replace(/\s/g, "");
  const update = (preferred = sections.value) => {
    const query = normalize(search.value);
    const matches = field.options.filter(([id, name, type]) =>
      (!family.value || type === family.value) && (normalize(id).includes(query) || normalize(name).includes(query)));
    sections.replaceChildren(...matches.map(([id, name]) => new Option(name, id)));
    if (!matches.length) sections.add(new Option("該当する断面なし", ""));
    else if (matches.some(([id]) => id === preferred)) sections.value = preferred;
  };
  family.addEventListener("change", () => update());
  search.addEventListener("input", () => update());
  update(selected);
  fieldArea.append(labeled("鋼材の種類", family), labeled("寸法・記号で検索", search), labeled("鋼材断面", sections, true));
}

function showForm(data) {
  activeForm = data;
  fieldArea.replaceChildren();
  for (const field of data.fields) {
    if (field.type === "timber") { timberFields(field); continue; }
    if (field.type === "steel") { steelFields(field); continue; }
    const value = field.value;
    const control = field.type === "select" ? select(field.options, value) : document.createElement("input");
    control.name = field.key;
    control.required = !field.optional;
    if (field.type !== "select") {
      control.type = field.type;
      control.value = value;
      control.readOnly = !!field.readOnly;
      if (field.type === "number") {
        control.step = "any";
        if (!field.signed) control.min = field.minimum ?? "1";
      }
    }
    fieldArea.append(labeled(field.label, control));
  }
  windowFieldVisibility(fieldArea);
  doorFieldVisibility(fieldArea);
  if (data.kind === "wall") fieldArea.addEventListener("input", syncWallOffsets);
  else fieldArea.removeEventListener("input", syncWallOffsets);
  const structuralName = ["column", "beam"].includes(data.kind) ? project.systems[data.system] : "";
  byId("form-title").textContent = editing ? "編集 · " + data.name : [structuralName, data.title].filter(Boolean).join(" ");
  byId("back").hidden = !editing;
  byId("tip").textContent = editing ? "反映すると要素の内部形状を再生成します。直接加えた加工も置き換わります。" : data.tip;
  byId("submit").hidden = !editing;
  renderLayers(data.patterns, data.layers ?? []);
  renderOpenings(editing ? data.openings : [], data.sashOptions, data.doorDirections);
  if (data.focusOpening) {
    const opening = [...byId("openings").children].find(box => box.dataset.id === data.focusOpening);
    if (opening) {
      opening.classList.add("focused-opening");
      opening.scrollIntoView({block: "nearest"});
      const field = opening.querySelector('[name="door_type"], [name="window_type"]') ?? opening.querySelector('[name="width"]');
      field?.focus({preventScroll: true});
    }
  }
}

function doorFieldVisibility(area) {
  const type = area.querySelector('[name="door_type"]');
  if (!type) return;
  const child = area.querySelector('[name="inactive_width"]');
  const update = () => { child.closest("label").hidden = child.disabled = type.value !== "unequal"; };
  type.addEventListener("change", update);
  update();
}

function windowFieldVisibility(area) {
  const mode = area.querySelector('[name="mount_mode"]');
  if (!mode) return;
  const distance = area.querySelector('[name="mount_offset"]');
  const type = area.querySelector('[name="window_type"]');
  const hinge = area.querySelector('[name="hinge"]');
  const update = () => {
    distance.closest("label").hidden = distance.disabled = mode.value === "flush";
    if (hinge) hinge.closest("label").hidden = hinge.disabled = !["single_slide", "casement", "vertical_awning"].includes(type.value);
  };
  mode.addEventListener("change", update);
  type.addEventListener("change", update);
  update();
}

function renderLayers(patterns, items) {
  byId("composition").hidden = !patterns;
  byId("layers").replaceChildren();
  if (!patterns) return;

  byId("layer-order").textContent = activeForm.kind === "wall" ? "壁芯に沿って見た左側から右側の順。" : "床天端から下向きの順。";
  for (const item of items) addLayer(item, patterns);
  sumLayers();
}

function addLayer(item, patterns) {
  const row = document.createElement("div");
  row.className = "layer";
  const name = document.createElement("input");
  name.name = "name";
  name.maxLength = 60;
  name.required = true;
  name.value = item.name;
  const thickness = document.createElement("input");
  thickness.name = "thickness";
  thickness.type = "number";
  thickness.min = "1";
  thickness.step = "any";
  thickness.required = true;
  thickness.value = item.thickness;
  thickness.addEventListener("input", sumLayers);
  const pattern = select(patterns, item.pattern);
  pattern.name = "pattern";
  const remove = document.createElement("button");
  remove.type = "button";
  remove.textContent = "×";
  remove.setAttribute("aria-label", "この層を削除");
  remove.addEventListener("click", () => { row.remove(); sumLayers(); saveDefaults(); });
  row.append(labeled("層名", name), labeled("厚さ mm", thickness), labeled("ハッチ", pattern), remove);
  byId("layers").append(row);
}

function layerValues() {
  if (byId("composition").hidden) return undefined;
  return [...byId("layers").children].map(row =>
    Object.fromEntries([...row.querySelectorAll("[name]")].map(input => [input.name, input.value])));
}

function sumLayers() {
  const layers = layerValues() ?? [];
  const field = fieldArea.querySelector('[name="thickness"]');
  const sum = layers.reduce((total, layer) => total + Number(layer.thickness), 0);
  field.readOnly = layers.length > 0;
  if (layers.length) field.value = sum;
  byId("add-layer").disabled = layers.length >= 12;
  byId("total-layers").textContent = layers.length ? "合計 " + Number(sum.toFixed(3)) + " mm" : "単層";
  if (activeForm.kind === "wall") syncWallOffsets();
}

function syncWallOffsets() {
  const alignment = fieldArea.querySelector('[name="alignment"]');
  const outer = fieldArea.querySelector('[name="outer_offset"]');
  const inner = fieldArea.querySelector('[name="inner_offset"]');
  if (!outer || !inner) return;

  const enabled = alignment.value === "外・内寸法";
  const thickness = fieldArea.querySelector('[name="thickness"]');
  const layers = layerValues() ?? [];
  const layered = layers.length > 0;
  if (enabled && outer.disabled && Number(thickness.value) !== Number(outer.value) + Number(inner.value)) {
    outer.value = inner.value = Number(thickness.value) / 2;
  }
  for (const field of [outer, inner, fieldArea.querySelector('[name="outside_side"]')]) {
    field.closest("label").hidden = field.disabled = !enabled;
  }
  thickness.readOnly = enabled || layered;
  inner.readOnly = layered;
  outer.setCustomValidity("");
  if (!enabled) return;

  if (layered) {
    inner.value = outer.value === "" ? "" : Number((Number(thickness.value) - Number(outer.value)).toFixed(6));
  } else if (outer.value !== "" && inner.value !== "") {
    const total = Number(outer.value) + Number(inner.value);
    thickness.value = Number(total.toFixed(6));
    if (total < 1) outer.setCustomValidity("外面・内面の寸法の合計を1 mm以上にしてください。");
  }
}

byId("add-layer").addEventListener("click", () => {
  const count = byId("layers").children.length;
  const thickness = count ? 20 : Number(fieldArea.querySelector('[name="thickness"]').value) || 150;
  addLayer({name: "層 " + (count + 1), thickness, pattern: count % 2 ? "reverse" : "diag"}, activeForm.patterns);
  sumLayers();
  saveDefaults();
});

function renderOpenings(items = [], sashOptions = [], doorDirections = {}) {
  const container = byId("openings");
  container.hidden = items.length === 0;
  container.replaceChildren(...items.map(item => {
    const box = document.createElement("fieldset");
    box.dataset.id = item.id;
    const legend = document.createElement("legend");
    legend.textContent = [item.label, item.mark, "区間 " + (item.segment + 1)].filter(Boolean).join(" · ");
    const inputs = document.createElement("div");
    inputs.className = "fields";
    const keys = [["mark", "建具記号"], ["offset", "区間始点から中心 (mm)"], ["width", "幅 (mm)"], ["height", "高さ (mm)"]];
    if (item.kind === "window") keys.push(["sill", "腰高 (mm)"]);
    for (const [key, label] of keys) {
      const input = document.createElement("input");
      input.name = key;
      input.value = item[key];
      if (key !== "mark") {
        input.type = "number";
        input.min = key === "sill" ? "0" : "1";
        input.step = "any";
        input.required = true;
      }
      inputs.append(labeled(label, input));
    }
    for (const field of item.fields ?? []) {
      const input = field.options ? select(field.options, field.value) : document.createElement("input");
      input.name = field.key;
      if (!field.options) {
        input.type = "number";
        input.value = field.value;
        input.min = "1";
        input.step = "any";
        input.required = true;
      }
      inputs.append(labeled(field.label, input));
    }
    windowFieldVisibility(inputs);
    doorFieldVisibility(inputs);
    if (item.kind === "door") {
      const type = inputs.querySelector('[name="door_type"]');
      const direction = select([], "");
      const title = document.createElement("span");
      const label = document.createElement("label");
      label.className = "wide";
      label.append(title, direction);
      const update = () => {
        const {key, options} = doorDirections[type.value];
        const preferred = direction.name === key && !direction.disabled ? direction.value : item[key];
        const control = select(options, preferred);
        direction.replaceChildren(...control.children);
        direction.value = options.some(([id]) => id === preferred) ? preferred : (options[0]?.[0] ?? "");
        direction.name = key ?? "";
        label.hidden = direction.disabled = !key;
        title.textContent = key === "swing" ? "開き勝手" : "引く方向・壁側";
        if (type.value === "fold") title.textContent = "折りたたむ端・壁側";
        if (type.value === "split") title.textContent = "戸を付ける壁側";
      };
      type.addEventListener("change", update);
      inputs.append(label);
      update();
    }
    if (item.kind === "window" && (sashOptions.length || item.sash)) {
      const id = item.sash?.product_id ?? "";
      const windowType = inputs.querySelector('[name="window_type"]');
      const originalType = windowType.value;
      const options = [...sashOptions];
      if (id && !options.some(option => option[0] === id)) options.push([id, id + "（保存済み）", originalType]);
      const product = select([], "");
      product.name = "product";
      const update = preferred => {
        const choices = options.filter(([value, , type]) =>
          !type || type === windowType.value || (value === id && windowType.value === originalType));
        const control = select([["", "標準の簡易サッシ"], ...choices], preferred);
        product.replaceChildren(...control.children);
        product.value = choices.some(option => option[0] === preferred) ? preferred : "";
      };
      windowType.addEventListener("change", () => update(product.value));
      update(id);
      inputs.append(labeled("サッシの形状", product, true));
    }
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "この開口を削除";
    remove.addEventListener("click", () => box.remove());
    box.append(legend, inputs, remove);
    return box;
  }));
}

function openingValues() {
  return [...byId("openings").children].map(box => ({
    id: box.dataset.id,
    ...Object.fromEntries([...box.querySelectorAll("[name]:not(:disabled)")].map(input => [input.name, input.value]))
  }));
}

window.PaletteUI = {
  project(data) {
    const newModel = project?.token !== data.token;
    project = data;
    document.documentElement.classList.toggle("dark", !!data.dark);
    byId("work-background").setAttribute("aria-pressed", !!data.dark);
    byId("work-background").textContent = data.dark ? "作業背景を元に戻す" : "暗い作業背景";
    activeSystem = data.system;
    const levels = data.levels.map(([name, z]) => [name, name + " · " + z + " mm"]);
    const control = select([...levels, ["", "高さを手入力"]], data.level ?? "");
    byId("level").replaceChildren(...control.children);
    byId("level").value = data.level ?? "";
    byId("elevation").value = data.z;
    syncElevation();
    if (newModel) {
      activeForm = null;
      editing = false;
      byId("systems").replaceChildren(...Object.entries(data.systems).map(([id, name]) =>
        optionButton(name, id, system => saveContext({system}), id)));
      byId("tools").replaceChildren(...Object.entries(data.tools).map(([kind, [name]]) =>
        optionButton(name, kind, tool => sketchup.activateTool(project.token, tool), kind)));
    }
    markActive();
  },
  tool(data) {
    activeTool = data.kind;
    editing = false;
    markActive();
    showForm(data);
    PaletteUI.message({text: ""});
  },
  selection(item) {
    byId("selection").textContent = item ? item.name + (item.linked ? " · 追従あり" : "") : "要素を選択すると編集できます";
    byId("edit").disabled = !item || item.locked;
    byId("follow").disabled = !item?.canFollow || item.locked;
    byId("follow").textContent = item?.followLabel || "関連付け";
    byId("wall-head-section").hidden = !item?.wallHead;
    byId("wall-head-current").textContent = item?.wallHead || "";
    byId("wall-head").disabled = !item?.wallHead || item.locked;
    if (editing && activeForm?.id !== item?.id) sketchup.showTool();
  },
  edit(data) {
    editing = true;
    showForm(data);
    PaletteUI.message({text: ""});
  },
  message({text, error}) {
    byId("status").textContent = text;
    byId("status").classList.toggle("error", !!error);
  }
};

function syncElevation() {
  const datum = project.levels.find(([name]) => name === byId("level").value);
  byId("elevation").readOnly = !!datum;
  if (datum) byId("elevation").value = datum[1];
  else if (byId("elevation").value === "") byId("elevation").value = 0;
}

function saveContext(values) {
  if (project) sketchup.drawContext(JSON.stringify({token: project.token, ...values}));
}

function saveLevel() {
  if (byId("elevation").reportValidity()) saveContext({level: byId("level").value, z: byId("elevation").value});
}

byId("level").addEventListener("change", () => { syncElevation(); saveLevel(); });
byId("elevation").addEventListener("change", saveLevel);
byId("back").addEventListener("click", () => sketchup.showTool());
byId("edit").addEventListener("click", () => sketchup.editSelection());
byId("repair-grid").addEventListener("click", () => sketchup.repairGrid());
byId("work-background").addEventListener("click", () => sketchup.toggleWorkBackground());
byId("edit-plan-opening").addEventListener("click", () => {
  if (!project || !byId("elevation").reportValidity()) return;
  sketchup.editPlanOpening(JSON.stringify({token: project.token, level: byId("level").value, z: byId("elevation").value}));
});
byId("schedule").addEventListener("click", () => sketchup.schedule());
byId("drawings").addEventListener("click", () => sketchup.drawings());
byId("edit-levels").addEventListener("click", () => sketchup.editLevels());
byId("follow").addEventListener("click", () => sketchup.followSelection());
byId("wall-head").addEventListener("click", () => sketchup.wallHead());
byId("form").addEventListener("change", saveDefaults);
byId("form").addEventListener("submit", event => {
  event.preventDefault();
  if (!activeForm) return;
  if (editing) sketchup.applyEdit(JSON.stringify({id: activeForm.id, values: values(), openings: openingValues(), layers: layerValues()}));
  else saveDefaults();
});

document.addEventListener("DOMContentLoaded", () => sketchup.ready());
