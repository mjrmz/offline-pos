import React, {useEffect, useState} from 'react';
import {api} from './api';

export type Account = {id:string;username:string;displayName:string;role:string;lastLoginAt:string|null;passwordChangedAt:string|null};
export function AccountSecurity({account,onAccount,recovery,bootstrap,onSignOut}:{account:Account|null;onAccount:(account:Account)=>void;recovery:boolean;bootstrap:boolean;onSignOut:()=>void}){
  const [displayName,setDisplayName]=useState(account?.displayName??'');
  const [username,setUsername]=useState(account?.username??'');
  const [currentPassword,setCurrentPassword]=useState('');
  const [newPassword,setNewPassword]=useState('');
  const [confirm,setConfirm]=useState('');
  const [visible,setVisible]=useState(false);
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState('');
  const [success,setSuccess]=useState('');
  useEffect(()=>{setDisplayName(account?.displayName??'');setUsername(account?.username??'');},[account?.displayName,account?.username]);
  const run=async(task:()=>Promise<void>)=>{setBusy(true);setError('');setSuccess('');try{await task();}catch(e){setError(e instanceof Error?e.message:'Request failed.');}finally{setBusy(false);}};
  const validPassword=newPassword.length>=12&&newPassword.length<=128;
  const save=()=>void run(async()=>{
    if(!/^[A-Za-z0-9._-]{3,64}$/.test(username.trim())||!displayName.trim()){setError('Enter a display name and a username with 3–64 letters, numbers, dots, underscores or hyphens.');return;}
    const response=await api<{account:Account}>('/admin/account','PATCH',{username:username.trim(),displayName:displayName.trim()});
    onAccount(response.account);setSuccess('Account details saved.');
  });
  const changePassword=()=>void run(async()=>{
    if(!validPassword||newPassword!==confirm||(!recovery&&!currentPassword)){setError('Check the password fields. Use at least 12 characters and matching new passwords.');return;}
    if(bootstrap){
      await api('/admin/account/bootstrap','POST',{username:username.trim(),displayName:displayName.trim(),password:newPassword});
      onSignOut();return;
    }
    if(recovery){await api('/admin/account/recover','POST',{newPassword});onSignOut();return;}
    if(!window.confirm('Change your password and sign out all other sessions?'))return;
    await api('/admin/account/password','POST',{currentPassword,newPassword});
    setCurrentPassword('');setNewPassword('');setConfirm('');setSuccess('Password changed. Other sessions have been signed out.');
  });
  const signOutOthers=()=>void run(async()=>{if(!window.confirm('Sign out all other sessions for this account?'))return;await api('/admin/account/sessions/revoke-others','POST');setSuccess('Other sessions signed out.');});
  const title=bootstrap?'Create your Owner account':recovery?'Recover Owner access':'Account & Security';
  return <><div className="page-head"><div><span className="eyebrow">SETTINGS</span><h1>{title}</h1><p>{bootstrap?'Create the primary account using the environment bootstrap login.':recovery?'Set a new Owner password using the emergency recovery credential.':'Manage your profile, password and signed-in sessions.'}</p></div></div>
    {error&&<div className="error banner" role="alert">{error}</div>}{success&&<div className="notice banner" role="status">{success}</div>}
    <div className="settings-grid"><section className="settings-card"><div className="settings-card-head"><div><h2>Account</h2><p>Your name appears in the dashboard. Usernames are unique.</p></div></div><div className="settings-fields"><label>Display name<input value={displayName} onChange={e=>setDisplayName(e.target.value)} maxLength={100}/></label><label>Username<input value={username} onChange={e=>setUsername(e.target.value)} maxLength={64} autoComplete="username"/></label><label>Role<input readOnly value="Owner" aria-label="Role"/></label></div>{!recovery&&<button className="primary" disabled={busy} onClick={save}>Save changes</button>}</section>
    <section className="settings-card"><div className="settings-card-head"><div><h2>{recovery?'Set Owner password':'Change password'}</h2><p>Use at least 12 characters. A long, unique passphrase works well.</p></div></div><div className="settings-fields">{!recovery&&<label>Current password<input type={visible?'text':'password'} value={currentPassword} onChange={e=>setCurrentPassword(e.target.value)} autoComplete="current-password"/></label>}<label>New password<input type={visible?'text':'password'} value={newPassword} onChange={e=>setNewPassword(e.target.value)} autoComplete="new-password"/></label><label>Confirm new password<input type={visible?'text':'password'} value={confirm} onChange={e=>setConfirm(e.target.value)} autoComplete="new-password"/></label><label className="check-row"><input type="checkbox" checked={visible} onChange={e=>setVisible(e.target.checked)}/> Show passwords</label><p className="strength" role="status">{!newPassword?'Enter a new password':validPassword?'Length requirement met':'Add more characters (12 minimum)'}</p></div><button className="primary" disabled={busy} onClick={changePassword}>{bootstrap?'Create account':recovery?'Reset Owner password':'Change password'}</button></section>
    {!recovery&&<section className="settings-card"><div className="settings-card-head"><div><h2>Sessions</h2><p>Review access to this account.</p></div></div><p><span className="chip active">Current session</span> This browser is signed in.</p><p className="muted">Last login: {account?.lastLoginAt?new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'}).format(new Date(account.lastLoginAt)):'This is your first session'}</p><button disabled={busy} onClick={signOutOthers}>Sign out all other sessions</button></section>}</div>
  </>;
}
