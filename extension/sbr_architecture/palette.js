"use strict";

const byId = id => document.getElementById(id);
const fieldArea = byId("properties");
const drafts = new Map();
let project, activeTool = "wall", activeSystem, activeForm, selectedId;
let editing = false;
let request = 0;

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

function remember() {
  if (activeForm && !editing) drafts.set(draftKey(activeForm), {values: values(), layers: layerValues()});
}

function draftKey(form) {
  return ["column", "beam"].includes(form.kind) ? form.kind + ":" + form.system : form.kind;
}

function choose(kind, system) {
  remember();
  activeTool = kind;
  activeSystem = system;
  editing = false;
  activeForm = null;
  markActive();
  byId("back").hidden = true;
  byId("submit").disabled = true;
  fieldArea.replaceChildren();
  byId("composition").hidden = true;
  byId("layers").replaceChildren();
  byId("openings").hidden = true;
  byId("openings").replaceChildren();
  byId("form-title").textContent = project.tools[kind][0];
  byId("tip").textContent = "設定を読み込み中…";
  PaletteUI.message({text: ""});
  sketchup.schema(++request, kind, system);
}

function timberFields(field, draft) {
  const role = select(field.options.map(([id, name]) => [id, name]), draft.role ?? field.role);
  const sections = select([], "");
  role.name = "role";
  sections.name = field.key;
  const update = preferred => {
    const [, , defaultSection, options] = field.options.find(entry => entry[0] === role.value);
    sections.replaceChildren(...options.map(([id, name]) => new Option(name + " mm", id)));
    sections.value = options.some(([id]) => id === preferred) ? preferred : defaultSection;
  };
  role.addEventListener("change", () => update());
  update(draft[field.key] ?? field.value);
  fieldArea.append(labeled("役割", role), labeled("断面 (mm)", sections));
}

const familyNames = {H:"H形鋼", BOX:"角形鋼管", PIPE:"丸鋼管", ANGLE:"山形鋼", CHANNEL:"溝形鋼",
                     I:"I形鋼", C:"軽量形鋼", FB:"平鋼", CT:"CT形鋼", HB:"六角鋼", SB:"角鋼", RB:"丸鋼"};

function steelFields(field, draft) {
  const families = [...new Set(field.options.map(option => option[2]))];
  const selected = draft[field.key] ?? field.value;
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
  const draft = editing ? {} : drafts.get(draftKey(data)) ?? {};
  fieldArea.replaceChildren();
  for (const field of data.fields) {
    if (field.type === "timber") { timberFields(field, draft.values ?? {}); continue; }
    if (field.type === "steel") { steelFields(field, draft.values ?? {}); continue; }
    const value = draft.values?.[field.key] ?? field.value;
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
  const structuralName = ["column", "beam"].includes(data.kind) ? project.systems[data.system] : "";
  byId("form-title").textContent = editing ? "編集 · " + data.name : [structuralName, data.title].filter(Boolean).join(" ");
  byId("back").hidden = !editing;
  byId("tip").textContent = editing ? "反映すると要素の内部形状を再生成します。直接加えた加工も置き換わります。" : data.tip;
  byId("submit").textContent = editing ? "変更を反映" : "作図を開始";
  byId("submit").disabled = false;
  renderLayers(data.patterns, draft.layers ?? data.layers ?? []);
  renderOpenings(editing ? data.openings : [], data.sashOptions);
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
  remove.addEventListener("click", () => { row.remove(); sumLayers(); });
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
}

byId("add-layer").addEventListener("click", () => {
  const count = byId("layers").children.length;
  const thickness = count ? 20 : Number(fieldArea.querySelector('[name="thickness"]').value) || 150;
  addLayer({name: "層 " + (count + 1), thickness, pattern: count % 2 ? "reverse" : "diag"}, activeForm.patterns);
  sumLayers();
});

function renderOpenings(items = [], sashOptions = []) {
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
    if (item.kind === "window" && (sashOptions.length || item.sash)) {
      const id = item.sash?.product_id ?? "";
      const options = [["", "開口のみ"], ...sashOptions];
      if (id && !options.some(option => option[0] === id)) options.push([id, id + "（保存済み）"]);
      const product = select(options, id);
      product.name = "product";
      const side = select([["right", "壁芯の右側"], ["left", "壁芯の左側"]], item.sash?.side ?? "right");
      side.name = "side";
      const inset = document.createElement("input");
      inset.name = "inset";
      inset.type = "number";
      inset.min = "0";
      inset.step = "any";
      inset.value = item.sash?.inset ?? "0";
      const sideLabel = labeled("サッシの外側", side);
      const insetLabel = labeled("外側からの引込み (mm)", inset);
      const toggle = () => { sideLabel.hidden = insetLabel.hidden = !product.value; };
      product.addEventListener("change", toggle);
      toggle();
      inputs.append(labeled("LIXILサッシ", product, true), sideLabel, insetLabel);
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
    ...Object.fromEntries([...box.querySelectorAll("[name]")].map(input => [input.name, input.value]))
  }));
}

window.PaletteUI = {
  project(data) {
    const newModel = project?.token !== data.token;
    project = data;
    const lastLevel = newModel ? data.level : byId("level").value;
    const levels = data.levels.map(([name, z]) => [name, name + " · " + z + " mm"]);
    const control = select([...levels, ["", "高さを手入力"]], lastLevel ?? "");
    const chosen = control.value;
    byId("level").replaceChildren(...control.children);
    byId("level").value = chosen;
    if (newModel && !chosen) byId("elevation").value = 0;
    if (newModel || byId("level").value) syncElevation();
    if (!newModel) return;

    drafts.clear();
    activeForm = null;
    editing = false;
    byId("systems").replaceChildren(...Object.entries(data.systems).map(([id, name]) =>
      optionButton(name, id, system => choose(activeTool, system))));
    byId("tools").replaceChildren(...Object.entries(data.tools).map(([kind, [name]]) =>
      optionButton(name, kind, tool => choose(tool, activeSystem), kind)));
    choose("wall", data.system);
  },
  schema([id, data]) {
    if (id === request && !editing) showForm(data);
  },
  selection(item) {
    selectedId = item?.id;
    byId("selection").textContent = item ? item.name + (item.linked ? " · 追従あり" : "") : "要素を選択すると編集できます";
    byId("edit").disabled = !item || item.locked;
    byId("follow").disabled = !item?.canFollow || item.locked;
    byId("follow").textContent = item?.followLabel || "関連付け";
    byId("wall-head-section").hidden = !item?.wallHead;
    byId("wall-head-current").textContent = item?.wallHead || "";
    byId("wall-head").disabled = !item?.wallHead || item.locked;
    if (editing && activeForm?.id !== selectedId) {
      choose(activeTool, activeSystem);
      PaletteUI.message({text: "選択が変わったため、編集を終了しました。"});
    }
  },
  edit(data) {
    remember();
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

byId("level").addEventListener("change", syncElevation);
byId("back").addEventListener("click", () => choose(activeTool, activeSystem));
byId("edit").addEventListener("click", () => sketchup.editSelection());
byId("schedule").addEventListener("click", () => sketchup.schedule());
byId("drawings").addEventListener("click", () => sketchup.drawings());
byId("edit-levels").addEventListener("click", () => sketchup.editLevels());
byId("follow").addEventListener("click", () => sketchup.followSelection());
byId("wall-head").addEventListener("click", () => sketchup.wallHead());
byId("form").addEventListener("submit", event => {
  event.preventDefault();
  if (!activeForm) return;
  if (editing) sketchup.applyEdit(JSON.stringify({id: activeForm.id, values: values(), openings: openingValues(), layers: layerValues()}));
  else if (byId("elevation").reportValidity()) {
    remember();
    sketchup.place(JSON.stringify({token: project.token, kind: activeTool, system: activeSystem,
                                  level: byId("level").value, z: byId("elevation").value, values: values(), layers: layerValues()}));
  }
});

document.addEventListener("DOMContentLoaded", () => sketchup.ready());
