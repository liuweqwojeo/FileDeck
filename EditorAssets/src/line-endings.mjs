import { StateEffect, StateField } from "@codemirror/state";
import { invertedEffects } from "@codemirror/commands";

// CodeMirror 的文档用 LF 定位字符；磁盘换行单独保存，并随撤销历史恢复。
export function splitLineEndings(text) {
  const endings = [];
  const normalized = text.replace(/\r\n|\r|\n/g, (ending) => {
    endings.push(ending);
    return "\n";
  });
  return { normalized, endings, preferred: endings[0] ?? "\n" };
}

export const restoreLineEndings = StateEffect.define();

export const lineEndingField = StateField.define({
  create: () => ({ endings: [], preferred: "\n" }),
  update(value, transaction) {
    let updated = value;
    if (transaction.docChanged) {
      let changesLineStructure = false;
      transaction.changes.iterChanges((from, to, _newFrom, _newTo, inserted) => {
        if (inserted.lines > 1 || transaction.startState.doc.lineAt(from).number !== transaction.startState.doc.lineAt(to).number) changesLineStructure = true;
      });
      // 普通同一行输入不改变行尾映射，复用不可变数组及桥接偏移缓存，避免每字复制全部行尾。
      if (changesLineStructure) {
        const endings = [];
        let cursor = 0;
        transaction.changes.iterChanges((from, to, _newFrom, _newTo, inserted) => {
          const first = transaction.startState.doc.lineAt(from).number - 1;
          const last = transaction.startState.doc.lineAt(to).number - 1;
          for (let index = cursor; index < first; index++) endings.push(value.endings[index]);
          for (let line = 1; line < inserted.lines; line++) endings.push(value.preferred);
          cursor = last;
        });
        for (let index = cursor; index < value.endings.length; index++) endings.push(value.endings[index]);
        updated = { endings, preferred: value.preferred };
      }
    }
    // 历史合并时反向 effect 按新到旧排列，最后一个快照对应整个撤销组开始前的换行。
    for (const effect of transaction.effects) {
      if (effect.is(restoreLineEndings)) updated = effect.value;
    }
    if (updated.endings.length !== transaction.newDoc.lines - 1) {
      throw new Error("换行映射与文档不一致，已停止编辑以避免改写原换行。");
    }
    return updated;
  },
});

export const preserveLineEndingHistory = invertedEffects.of((transaction) =>
  transaction.docChanged ? [restoreLineEndings.of(transaction.startState.field(lineEndingField))] : [],
);

export function lineEndingExtensions(text) {
  const original = splitLineEndings(text);
  return [lineEndingField.init(() => ({ endings: original.endings, preferred: original.preferred })), preserveLineEndingHistory];
}

export function originalText(state) {
  const { endings } = state.field(lineEndingField);
  let index = 0;
  return state.doc.toString().replace(/\n/g, () => endings[index++]);
}

// 全文 JSON 排版保留原有换行序列；额外生成的换行沿用原文第一个分隔符。
export function lineEndingsForFormattedText(state, formatted) {
  const original = state.field(lineEndingField);
  const count = (formatted.match(/\n/g) ?? []).length;
  return {
    preferred: original.preferred,
    endings: Array.from({ length: count }, (_, index) => original.endings[index] ?? original.preferred),
  };
}
