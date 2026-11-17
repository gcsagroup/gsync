// 隔离世界脚本：不注册 window 消息通道，不进入 iframe，不自动提交表单。
(()=>{
  if(window.top!==window||location.protocol!=='https:'||globalThis.__pbsyncContentInstalled)return;
  globalThis.__pbsyncContentInstalled=true;
  const api=globalThis.browser??chrome;
  const documentKey = crypto.randomUUID();
  const visible=element=>{const style=getComputedStyle(element),rect=element.getBoundingClientRect();return !element.disabled&&!element.readOnly&&style.visibility==='visible'&&style.display!=='none'&&Number(style.opacity)!==0&&rect.width>0&&rect.height>0&&element.getClientRects().length>0;};
  function fields(capturing=false, form=null){const passwords=[...(form??document).querySelectorAll('input[type="password"]')].filter(visible);const newFields=passwords.filter(p=>p.autocomplete==='new-password');const candidates=capturing&&newFields.length?newFields:passwords;if(!candidates.length||(!capturing&&candidates.length!==1)||(candidates.length>1&&(!newFields.length||!candidates.every(p=>p.value===candidates[0].value))))throw new Error('无法唯一确定密码，或两次输入的新密码不同');const password=candidates[0],scope=password.form??document;const users=[...scope.querySelectorAll('input[autocomplete="username"],input[type="email"],input[type="text"]')].filter(visible);const explicit=users.filter(e=>e.autocomplete==='username');const user=explicit.length===1?explicit[0]:users.length===1?users[0]:null;if(!user)throw new Error('无法唯一确定用户名输入框');if(password.form){const action=new URL(password.form.action||location.href,location.href);if(action.origin!==location.origin)throw new Error('表单将提交到其他网站，已拒绝填充');}return {user,password};}
  const set=(element,value)=>{Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(element,value);element.dispatchEvent(new Event('input',{bubbles:true}));element.dispatchEvent(new Event('change',{bubbles:true}));};
  async function capture(submitted=false,form=null){const {user,password}=fields(true,form);if(!password.value)throw new Error('密码输入框为空');return api.runtime.sendMessage({action:'saveCandidate',submitted,url:location.href,username:user.value,password:password.value});}
  api.runtime.onMessage.addListener((message,sender,reply)=>{
    if(sender.id!==api.runtime.id||new URL(message.expectedURL??'https://invalid.example').origin!==location.origin)return;
    try{
      if(message.action==='identify'){reply({key:documentKey});return;}
      if(message.action==='waitForFocus'){
        const valid=()=>message.documentKey===documentKey && location.href===message.expectedURL;
        const focused=()=>valid() && document.hasFocus() && !document.hidden;
        if(focused()){reply({ready:true});return;}
        // 系统确认框关闭与网页恢复焦点异步发生。等待期间页面没有密码。
        const start=Date.now();
        const timer=setInterval(()=>{
          if(focused() || !valid() || Date.now()-start>=8000){
            clearInterval(timer);reply({ready:focused()});
          }
        },60);
        return true;
      }
      if(message.action==='fill'){
        if(message.documentKey!==documentKey||message.expectedURL!==location.href)throw new Error('页面已变化，已取消填充');
        if(message.credential.origin!==location.origin)throw new Error('填充目标已改变');
        const {user,password}=fields();if(!document.hasFocus())throw new Error('页面不在前台，请返回网页后重试');
        set(user,message.credential.username);set(password,message.credential.password);reply({filled:true});
      }else if(message.action==='capture'){capture().then(reply).catch(error=>reply({error:error.message}));return true;}
    }catch(error){reply({error:error.message});}
  });
  document.addEventListener('submit',event=>{if(event.isTrusted && event.target instanceof HTMLFormElement)capture(true,event.target).catch(()=>{});},true);
  const nav=performance.getEntriesByType('navigation')[0];
  api.runtime.sendMessage({action:'pageReady',navigation:nav?.type,status:nav?.responseStatus,loginFormAbsent:!document.querySelector('input[type=password]')}).catch(()=>{});
})();
