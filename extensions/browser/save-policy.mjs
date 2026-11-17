// 候选仅跨一次顶层导航有效。提交、固定成功页与保险库会话都必须对应。
export const candidateKey = tabID => 'pending-login-' + tabID;
export const lifetime = 120_000;

export function committedCandidate(candidate, navigation) {
  if (!candidate || candidate.committed || !candidate.automatic ||
      navigation.url !== candidate.successURL || navigation.frameId !== 0 ||
      !navigation.documentId || navigation.documentId === candidate.documentId ||
      navigation.transitionType !== 'form_submit' ||
      navigation.transitionQualifiers?.some(q => ['forward_back','client_redirect','from_address_bar'].includes(q))) {
    return {...candidate, automatic:false};
  }
  return {...candidate, committed:navigation.documentId};
}

export function canAutoSave(candidate, sender, evidence, now = Date.now()) {
  return Boolean(candidate?.automatic && candidate.tabID === sender.tab.id &&
    sender.frameId === 0 && candidate.committed && candidate.committed === sender.documentId &&
    candidate.url !== sender.url && candidate.successURL === sender.url &&
    candidate.username && now >= candidate.time && now - candidate.time < lifetime &&
    evidence.navigation === 'navigate' && evidence.status >= 200 && evidence.status < 300 &&
    evidence.loginFormAbsent === true);
}
