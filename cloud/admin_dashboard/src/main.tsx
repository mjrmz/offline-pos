import React, {useEffect, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {api} from './api';
import {AccountSecurity, type Account} from './AccountSecurity';
import './style.css';

type Row = Record<string, any>;
type Page = 'Licenses' | 'Customers' | 'Devices' | 'Activity' | 'Settings';
type Modal = 'issue' | 'customer' | 'license' | 'customerDetail' | 'rotate' | 'revoke' | 'upgrade' | 'deactivate' | null;
const names: Record<string,string> = {non_bir:'Non-BIR',bir_ready:'BIR-ready',unactivated:'Unactivated',active:'Active',revoked:'Revoked',deactivated:'Deactivated',activate:'Device activated',reactivate:'Device reactivated',deactivate:'Device deactivated',revoke:'License revoked','license.issue':'License issued','license.activation_key_rotate':'Activation key rotated','license.edition_change':'Plan upgraded'};
const name = (v: unknown) => names[String(v)] ?? String(v ?? 'Unknown').replaceAll('_',' ');
const date = (v: unknown) => v ? new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'}).format(new Date(String(v))) : '—';
const err=(e:unknown,fallback:string)=>e instanceof Error?`${fallback} ${e.message}`:fallback;
type Resource = 'customers'|'licenses'|'plans'|'activity'|'devices';
type ResourceState = {loading:boolean;loaded:boolean;error:string};
const initialState=():Record<Resource,ResourceState>=>Object.fromEntries(
  (['customers','licenses','plans','activity','devices'] as Resource[]).map(key=>[key,{loading:key!=='devices',loaded:false,error:''}])
) as Record<Resource,ResourceState>;
const normalize=(v:string)=>v.trim().replace(/\s+/g,' ').toLocaleLowerCase();

export function App(){
  const [user,setUser]=useState('');
  const [account,setAccount]=useState<Account|null>(null);
  const [recovery,setRecovery]=useState(false);
  const [bootstrap,setBootstrap]=useState(false);
  const [authLoading,setAuthLoading]=useState(true);
  const [username,setUsername]=useState('');
  const [password,setPassword]=useState('');
  const [page,setPage]=useState<Page>('Licenses');
  const [customers,setCustomers]=useState<Row[]>([]);
  const [licenses,setLicenses]=useState<Row[]>([]);
  const [events,setEvents]=useState<Row[]>([]);
  const [plans,setPlans]=useState<Row[]>([]);
  const [devices,setDevices]=useState<Row[]>([]);
  const [detailDevices,setDetailDevices]=useState<Row[]>([]);
  const [detailLoading,setDetailLoading]=useState(false);
  const [detailError,setDetailError]=useState('');
  const [modal,setModal]=useState<Modal>(null);
  const [selected,setSelected]=useState<Row|null>(null);
  const [key,setKey]=useState<{value:string;kind:'issued'|'rotated'}|null>(null);
  const [copyStatus,setCopyStatus]=useState('');
  const [customerName,setCustomerName]=useState('');
  const [quickOpen,setQuickOpen]=useState(false);
  const [quickName,setQuickName]=useState('');
  const [quickPhone,setQuickPhone]=useState('');
  const [quickNotes,setQuickNotes]=useState('');
  const [customerSearch,setCustomerSearch]=useState('');
  const [customerId,setCustomerId]=useState('');
  const [planId,setPlanId]=useState('non_bir');
  const [maxDevices,setMaxDevices]=useState(1);
  const [maxReactivations,setMaxReactivations]=useState(3);
  const [search,setSearch]=useState('');
  const [statusFilter,setStatusFilter]=useState('all');
  const [planFilter,setPlanFilter]=useState('all');
  const [eventFilter,setEventFilter]=useState('all');
  const [resources,setResources]=useState(initialState);
  const [busy,setBusy]=useState(false);
  const busyRef=useRef(false);
  const [error,setError]=useState('');
  const [notice,setNotice]=useState('');
  useEffect(()=>{if(!notice)return;const timer=setTimeout(()=>setNotice(''),5000);return()=>clearTimeout(timer);},[notice]);
  const loadOne=async(which:Resource)=>{
    setResources(old=>({...old,[which]:{...old[which],loading:true,error:''}}));
    const routes:Record<Resource,string>={customers:'/admin/customers',licenses:'/admin/licenses',plans:'/admin/plans',activity:'/admin/activity',devices:'/admin/devices'};
    try {
      const result=await api<Row[]>(routes[which]);
      if(!Array.isArray(result))throw Error('Expected a list from the License API.');
      ({customers:setCustomers,licenses:setLicenses,plans:setPlans,activity:setEvents,devices:setDevices})[which](result);
      setResources(old=>({...old,[which]:{loading:false,loaded:true,error:''}}));
    } catch(e) {
      setResources(old=>({...old,[which]:{...old[which],loading:false,error:err(e,`${which[0].toUpperCase()+which.slice(1)} could not be loaded.`)}}));
    }
  };
  const loadAll=()=>Promise.allSettled((['customers','licenses','plans','activity'] as Resource[]).map(loadOne));
  useEffect(()=>{api('/admin/me').then(x=>{setUser(x.user);setAccount(x.account??null);setRecovery(Boolean(x.recovery));setBootstrap(Boolean(x.bootstrap));if(x.recovery)setPage('Settings');else return loadAll();}).catch(()=>{}).finally(()=>setAuthLoading(false));},[]);
  const action=async(fn:()=>Promise<void>,fallback:string)=>{
    if(busyRef.current)return;busyRef.current=true;setBusy(true);setError('');setNotice('');
    try{await fn();}catch(e){setError(err(e,fallback));}finally{busyRef.current=false;setBusy(false);}
  };
  const open=(m:Modal,row?:Row)=>{setModal(m);setSelected(row??null);setError('');setNotice('');setCopyStatus('');if(m==='issue'){setQuickOpen(false);setCustomerSearch('');}};
  const close=()=>{if(!busy){setModal(null);setSelected(null);setError('');}};
  const copy=async(value:string)=>{try{await navigator.clipboard.writeText(value);setCopyStatus('Copied');setTimeout(()=>setCopyStatus(''),2500);}catch{setCopyStatus('Clipboard unavailable. Select and copy the value.');}};
  const loadDetailDevices=async(id:string)=>{
    setDetailLoading(true);setDetailError('');
    try{setDetailDevices(await api<Row[]>(`/admin/licenses/${id}/devices`));}
    catch(e){setDetailError(err(e,'Failed to load license devices.'));}
    finally{setDetailLoading(false);}
  };
  const viewLicense=async(l:Row)=>{open('license',l);setDetailDevices([]);await loadDetailDevices(l.id);};
  const loadDevices=()=>loadOne('devices');
  const navigate=(p:Page)=>{setPage(p);setSearch('');setError('');if(p==='Devices')void loadDevices();};
  const related=(id:string)=>licenses.filter(l=>l.customer_id===id);
  const current=selected&&licenses.find(l=>l.id===selected.id)||selected;
  const filtered=licenses.filter(l=>`${l.business_name} ${l.id}`.toLowerCase().includes(search.toLowerCase())&&(statusFilter==='all'||l.status===statusFilter)&&(planFilter==='all'||l.plan_id===planFilter));
  const duplicate=customers.find(c=>normalize(String(c.business_name))===normalize(quickName));
  const saveCustomer=async(quick:boolean)=>{
    const businessName=(quick?quickName:customerName).trim();
    if(!businessName){setError('Enter a customer name.');return;}
    await action(async()=>{
      const created=await api<Row>('/admin/customers','POST',{businessName,contactPhone:quick&&quickPhone.trim()?quickPhone.trim():null,notes:quick&&quickNotes.trim()?quickNotes.trim():null});
      if(!created?.id||!created.business_name)throw Error('Customer save was not confirmed by the License API.');
      setCustomers(old=>[created,...old.filter(c=>c.id!==created.id)]);
      setResources(old=>({...old,customers:{loading:false,loaded:true,error:''}}));
      if(quick){setCustomerId(created.id);setQuickOpen(false);setQuickName('');setQuickPhone('');setQuickNotes('');setCustomerSearch('');}
      else{setCustomerName('');setModal(null);}
      setNotice('Customer created successfully.');
    },'Could not create customer.');
  };
  const issueLicense=async()=>{
    if(!customerId||!Number.isInteger(maxDevices)||maxDevices<1||!Number.isInteger(maxReactivations)||maxReactivations<0){
      setError('Select a customer and enter valid device and reactivation limits.');return;
    }
    await action(async()=>{
      const result=await api<Row>('/admin/licenses','POST',{customerId,planId,maxDevices,maxReactivations});
      if(!result?.id||!result.activationKey)throw Error('License issuance was not confirmed by the License API.');
      setKey({value:result.activationKey,kind:'issued'});
      void loadOne('licenses');
      void loadOne('activity');
    },'Could not issue license.');
  };
  const button=(text:string,fn:()=>void,cls='')=><button className={cls} onClick={fn} disabled={busy}>{text}</button>;
  if(authLoading)return <main className="auth">Checking admin session…</main>;
  if(!user)return <main className="auth"><div className="auth-card"><span className="eyebrow">MASD · ADMIN</span><h1>Licensing admin</h1><p className="muted">Sign in to manage customers and licenses.</p><form onSubmit={e=>{e.preventDefault();void action(async()=>{const x=await api('/admin/login','POST',{username,password});setUser(x.user);setAccount(x.account??null);setRecovery(Boolean(x.recovery));setBootstrap(Boolean(x.bootstrap));if(x.recovery)setPage('Settings');else await loadAll();setPassword('');},'Could not log in.');}}><label>Username<input aria-label="Username" value={username} onChange={e=>setUsername(e.target.value)} required/></label><label>Password<input aria-label="Password" type="password" value={password} onChange={e=>setPassword(e.target.value)} required/></label><button className="primary" disabled={busy}>{busy?'Signing in…':'Log in'}</button></form>{error&&<p role="alert" className="error">{error}</p>}</div></main>;
  return <div className="app-shell"><header className="topbar"><div><span className="eyebrow">MASD · ADMIN</span><strong>Licensing</strong></div><div className="account"><details className="avatar-menu"><summary aria-label="Account menu"><span className="avatar">{(account?.displayName??user).slice(0,1).toUpperCase()}</span><span>{account?.displayName??user}</span></summary><div className="menu"><button onClick={()=>navigate('Settings')}>My Account</button><button onClick={()=>navigate('Settings')}>Security</button><button onClick={()=>void action(async()=>{await api('/admin/logout','POST');setUser('');setAccount(null);setKey(null);},'Could not sign out.')}>Sign out</button></div></details></div></header>
    <nav aria-label="Admin sections" className="tabs">{(recovery?['Settings']:['Licenses','Customers','Devices','Activity','Settings'] as Page[]).map(p=><button key={p} className={page===p?'active':''} aria-current={page===p?'page':undefined} onClick={()=>navigate(p as Page)}>{p}</button>)}</nav>
    <main className="workspace">{error&&!modal&&<div className="error banner" role="alert">{error}</div>}{notice&&<div className="notice banner" role="status">{notice}</div>}
      {page==='Settings'&&<AccountSecurity account={account} onAccount={a=>{setAccount(a);setUser(a.username);}} recovery={recovery} bootstrap={bootstrap} onSignOut={()=>{setUser('');setAccount(null);setRecovery(false);setBootstrap(false);}}/>}
      {page==='Licenses'&&<><div className="page-head"><div><h1>Licenses</h1><p>Issue and manage access for customer POS devices.</p></div>{button('+ Issue license',()=>open('issue'),'primary')}</div><div className="toolbar"><input aria-label="Search licenses" placeholder="Search customer or License ID" value={search} onChange={e=>setSearch(e.target.value)}/><select aria-label="Filter status" value={statusFilter} onChange={e=>setStatusFilter(e.target.value)}><option value="all">All statuses</option>{['active','unactivated','revoked'].map(x=><option key={x} value={x}>{name(x)}</option>)}</select><select aria-label="Filter plan" value={planFilter} onChange={e=>setPlanFilter(e.target.value)}><option value="all">All plans</option>{plans.map(p=><option key={p.id} value={p.id}>{name(p.id)}</option>)}</select></div>{resources.licenses.error?<div className="error state" role="alert">Licenses could not be loaded. {resources.licenses.error} {button('Retry',()=>void loadOne('licenses'))}</div>:resources.licenses.loading?<p className="state">Loading licenses...</p>:filtered.length?<div className="list">{filtered.map(l=><article className="license-row" key={l.id}><div className="row-main"><strong>{l.business_name}</strong><span className="muted">Created {date(l.issued_at)}</span></div><div><small>Plan</small><span className="chip plan">{name(l.plan_id)}</span></div><div><small>Status</small><span className={`chip ${l.status}`}>{name(l.status)}</span></div><div><small>Devices</small><strong>{l.active_devices??0} / {l.max_devices}</strong></div><div className="row-actions">{button('View',()=>void viewLicense(l))}<details><summary aria-label={`More actions for ${l.business_name}`}>More</summary><div className="menu"><button disabled={l.status==='revoked'} onClick={()=>open('rotate',l)}>Rotate activation key</button><button disabled={l.status==='revoked'||l.plan_id==='bir_ready'} onClick={()=>open('upgrade',l)}>Upgrade to BIR-ready</button><button className="danger-text" disabled={l.status==='revoked'} onClick={()=>open('revoke',l)}>Revoke license</button></div></details></div></article>)}</div>:<div className="empty"><h2>{licenses.length?'No matching licenses':'No licenses yet'}</h2><p>{licenses.length?'Try a different search or filter.':'Issue your first license to activate a POS device.'}</p>{!licenses.length&&button('Issue license',()=>open('issue'),'primary')}</div>}</>}
      {page==='Customers'&&<><div className="page-head"><div><h1>Customers</h1><p>Find customers and review their licenses.</p></div>{button('+ Create customer',()=>open('customer'),'primary')}</div><div className="toolbar"><input aria-label="Search customers" placeholder="Search customer name" value={search} onChange={e=>setSearch(e.target.value)}/></div>{resources.customers.error?<div className="error state" role="alert">Customers could not be loaded. {resources.customers.error} {button('Retry',()=>void loadOne('customers'))}</div>:resources.customers.loading?<p className="state">Loading customers...</p>:customers.filter(c=>String(c.business_name).toLowerCase().includes(search.toLowerCase())).length?<div className="list">{customers.filter(c=>String(c.business_name).toLowerCase().includes(search.toLowerCase())).map(c=><article className="customer-row" key={c.id}><div><strong>{c.business_name}</strong><span className="muted">{related(c.id).length} licenses · {related(c.id).reduce((n,l)=>n+Number(l.active_devices??0),0)} active devices</span></div>{button('View',()=>open('customerDetail',c))}</article>)}</div>:<div className="empty"><h2>No customers found</h2><p>{customers.length?'Try a different search.':'Create a customer to get started.'}</p>{!customers.length&&button('Create customer',()=>open('customer'),'primary')}</div>}</>}
      {page==='Devices'&&<><div className="page-head"><div><h1>Devices</h1><p>Activated devices across customer licenses.</p></div>{button('Refresh',()=>void loadDevices())}</div>{resources.devices.error?<div className="error state" role="alert">Devices could not be loaded. {resources.devices.error} {button('Retry',()=>void loadOne('devices'))}</div>:resources.devices.loading?<p className="state">Loading devices...</p>:devices.length?<div className="list">{devices.map(d=>{const l=licenses.find(x=>x.id===d.license_id);return <article className="device-row" key={d.id}><div><strong>{d.business_name??l?.business_name??'Unknown customer'}</strong><span className="muted">License {String(d.license_id).slice(0,8)}…</span></div><div><small>Device fingerprint</small><code title={d.device_fingerprint}>{String(d.device_fingerprint).slice(0,16)}…</code></div><div><small>Activated</small><span>{date(d.activated_at)}</span></div><span className={`chip ${d.status}`}>{name(d.status)}</span><button disabled={d.status!=='active'||busy} onClick={()=>open('deactivate',d)}>Deactivate</button></article>;})}</div>:<div className="empty"><h2>No activated devices yet</h2><p>Devices appear here after a POS activates a license.</p></div>}</>}
      {page==='Activity'&&<><div className="page-head"><div><h1>Activity</h1><p>Recent license and activation events.</p></div>{button('Refresh',()=>void loadOne('activity'))}</div><div className="toolbar"><select aria-label="Filter event type" value={eventFilter} onChange={e=>setEventFilter(e.target.value)}><option value="all">All events</option>{Array.from(new Set(events.map(e=>e.event_type))).map(x=><option key={x} value={x}>{name(x)}</option>)}</select></div>{resources.activity.error?<div className="error state" role="alert">Activity could not be loaded. {resources.activity.error} {button('Retry',()=>void loadOne('activity'))}</div>:resources.activity.loading?<p className="state">Loading activity...</p>:events.filter(e=>eventFilter==='all'||e.event_type===eventFilter).length?<div className="timeline">{events.filter(e=>eventFilter==='all'||e.event_type===eventFilter).map(e=>{const l=licenses.find(x=>x.id===e.license_id);return <article key={e.id}><time>{date(e.created_at)}</time><strong>{name(e.event_type)}</strong><span>{l?.business_name??'License activity'}</span><details><summary>Event details</summary><p>License ID: <code>{e.license_id??'—'}</code></p>{e.reason&&<p>Reason: {e.reason}</p>}{e.device_id&&<p>Device ID: <code>{e.device_id}</code></p>}</details></article>;})}</div>:<div className="empty"><h2>No activity yet</h2><p>License and device events will appear here.</p></div>}</>}
    </main>
    {(modal||key)&&<div className="overlay" onMouseDown={e=>{if(e.target===e.currentTarget&&!key)close();}}><div className="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title">
      {key&&<><span className="success-mark">✓</span><h2 id="dialog-title">{key.kind==='issued'?'License issued successfully':'Activation key rotated'}</h2><p>Copy this activation key now. It will not be shown again.</p><div className="key-box"><small>Activation key</small><code aria-label="Activation key value">{key.value}</code></div>{button('Copy activation key',()=>void copy(key.value))}{copyStatus&&<span role="status" className="copy-feedback">{copyStatus}</span>}<div className="dialog-actions">{button('Done',()=>{setKey(null);close();},'primary')}</div></>}
      {!key&&modal==='issue'&&<><h2 id="dialog-title">Issue license</h2><p className="muted">Create a license and copy its one-time activation key.</p>
        <form className="dialog-form" onSubmit={e=>{e.preventDefault();if(!quickOpen)void issueLicense();}}>
          <label>Search existing customers
            <input placeholder="Search existing customers" value={customerSearch} onChange={e=>setCustomerSearch(e.target.value)}/>
          </label>
          <label>Customer
            <select value={customerId} onChange={e=>setCustomerId(e.target.value)} required>
              <option value="">Select customer</option>
              {customers.filter(c=>String(c.business_name).toLowerCase().includes(customerSearch.toLowerCase())||c.id===customerId).map(c=><option key={c.id} value={c.id}>{c.business_name}</option>)}
            </select>
          </label>
          {resources.customers.error&&<p className="error" role="alert">Existing customers could not be loaded. <button type="button" onClick={()=>void loadOne('customers')}>Retry</button></p>}
          <button className="quick-toggle" type="button" onClick={()=>{setQuickOpen(!quickOpen);setError('');}}>+ Quick add customer</button>
          {quickOpen&&<div className="quick-add"><h3>Quick add customer</h3><label>Customer name *<input aria-label="Quick customer name" value={quickName} onChange={e=>setQuickName(e.target.value)} maxLength={200}/></label><label>Phone<input aria-label="Quick customer phone" value={quickPhone} onChange={e=>setQuickPhone(e.target.value)} maxLength={100}/></label><label>Optional notes<textarea aria-label="Quick customer notes" value={quickNotes} onChange={e=>setQuickNotes(e.target.value)} maxLength={2000}/></label>
            {duplicate&&<div className="duplicate" role="alert">A customer with this name already exists. <button type="button" onClick={()=>{setCustomerId(duplicate.id);setQuickOpen(false);setQuickName('');setQuickPhone('');}}>Use existing customer</button></div>}
            <div className="quick-actions"><button type="button" onClick={()=>{setQuickOpen(false);setError('');}} disabled={busy}>Cancel</button><button type="button" className="primary" disabled={busy||!quickName.trim()||!!duplicate} onClick={()=>void saveCustomer(true)}>{busy?'Creating...':'Add customer'}</button></div>
          </div>}
          <label>Plan<select value={planId} onChange={e=>setPlanId(e.target.value)}>{plans.map(p=><option key={p.id} value={p.id}>{name(p.id)}</option>)}</select></label>
          <div className="form-grid"><label>Device limit<input type="number" min="1" max="100" value={maxDevices} onChange={e=>setMaxDevices(Number(e.target.value))} required/></label><label>Allowed reactivations<input type="number" min="0" max="100" value={maxReactivations} onChange={e=>setMaxReactivations(Number(e.target.value))} required/></label></div>
          {error&&<p className="error" role="alert">{error}</p>}
          <div className="dialog-actions"><button type="button" onClick={close} disabled={busy}>Cancel</button><button className="primary" disabled={busy||!customerId||quickOpen}>{busy?'Issuing...':'Issue license'}</button></div>
        </form></>}
      {!key&&modal==='customer'&&<><h2 id="dialog-title">Create customer</h2><form className="dialog-form" onSubmit={e=>{e.preventDefault();void saveCustomer(false);}}><label>Customer name<input aria-label="Customer name" value={customerName} onChange={e=>setCustomerName(e.target.value)} maxLength={200} required/></label>{error&&<p className="error" role="alert">{error}</p>}<div className="dialog-actions"><button type="button" onClick={close} disabled={busy}>Cancel</button><button className="primary" disabled={busy}>{busy?'Creating...':'Create customer'}</button></div></form></>}
      {!key&&modal==='license'&&current&&<><span className="eyebrow">LICENSE DETAIL</span><h2 id="dialog-title">{current.business_name}</h2><div className="detail-grid"><div><small>Plan</small><span className="chip plan">{name(current.plan_id)}</span></div><div><small>Status</small><span className={`chip ${current.status}`}>{name(current.status)}</span></div><div><small>Devices</small><strong>{current.active_devices??0} / {current.max_devices}</strong></div><div><small>Created</small><span>{date(current.issued_at)}</span></div></div><section className="detail-section"><h3>Activation key</h3><p>Not currently visible. A new key appears only after rotation.</p><button disabled={current.status==='revoked'} onClick={()=>open('rotate',current)}>Rotate activation key</button></section><section className="detail-section"><h3>License ID</h3><code className="id-value">{current.id}</code>{button('Copy License ID',()=>void copy(String(current.id)))}{copyStatus&&<span role="status" className="copy-feedback">{copyStatus}</span>}</section><section className="detail-section"><h3>Devices</h3>{detailError?<p className="error" role="alert">{detailError} {button('Retry',()=>void loadDetailDevices(String(current.id)))}</p>:detailLoading?<p>Loading devices...</p>:detailDevices.length?detailDevices.map(d=><p key={d.id}><code>{String(d.device_fingerprint).slice(0,16)}...</code> ? {name(d.status)} ? {date(d.activated_at)}</p>):<p>No activated devices yet.</p>}</section><section className="detail-section"><h3>Recent activity</h3>{events.filter(e=>e.license_id===current.id).slice(0,5).map(e=><p key={e.id}>{name(e.event_type)} · {date(e.created_at)}</p>)}{!events.some(e=>e.license_id===current.id)&&<p>No recent activity.</p>}</section>{error&&<p className="error" role="alert">{error}</p>}<div className="dialog-actions">{button('Close',close)}</div></>}
      {!key&&modal==='customerDetail'&&selected&&<><span className="eyebrow">CUSTOMER DETAIL</span><h2 id="dialog-title">{selected.business_name}</h2><p>{related(selected.id).length} licenses · {related(selected.id).reduce((n,l)=>n+Number(l.active_devices??0),0)} active devices</p><section className="detail-section"><h3>Licenses</h3>{related(selected.id).length?related(selected.id).map(l=><div className="customer-license" key={l.id}><span>{name(l.plan_id)} · {name(l.status)} · {l.active_devices??0}/{l.max_devices} devices</span>{button('View',()=>void viewLicense(l))}</div>):<p>No licenses yet.</p>}</section><div className="dialog-actions">{button('Close',close)}</div></>}
      {!key&&['rotate','revoke','upgrade','deactivate'].includes(modal??'')&&selected&&<><h2 id="dialog-title">{({rotate:'Rotate activation key?',revoke:'Revoke license?',upgrade:'Upgrade to BIR-ready?',deactivate:'Deactivate device?'} as Record<string,string>)[modal!]}</h2>{modal==='rotate'&&<p>The old activation key will stop working for new activations. Existing activated devices will remain valid.</p>}{modal==='revoke'&&<p>New activations will fail. Existing devices follow the current license validation rules. This action cannot be undone.</p>}{modal==='upgrade'&&<><p>Current plan: <strong>Non-BIR</strong><br/>New plan: <strong>BIR-ready</strong></p><p>Existing device and data behavior remains unchanged.</p></>}{modal==='deactivate'&&<p>This device will be marked deactivated. Reactivation follows the license’s existing limits.</p>}{error&&<p className="error" role="alert">{error}</p>}<div className="dialog-actions"><button onClick={close} disabled={busy}>Cancel</button><button className={modal==='revoke'||modal==='deactivate'?'danger':'primary'} disabled={busy} onClick={()=>void action(async()=>{if(modal==='rotate'){const x=await api(`/admin/licenses/${selected.id}/activation-key/rotate`,'POST');setKey({value:x.activationKey,kind:'rotated'});void loadOne('activity');}else if(modal==='revoke'){await api(`/admin/licenses/${selected.id}/revoke`,'POST');setModal(null);setNotice('License revoked.');await loadOne('licenses');void loadOne('activity');}else if(modal==='upgrade'){await api(`/admin/licenses/${selected.id}/edition`,'POST',{edition:'bir_ready'});setModal(null);setNotice('License upgraded to BIR-ready.');await loadOne('licenses');void loadOne('activity');}else{await api(`/admin/devices/${selected.id}/deactivate`,'POST');setModal(null);setNotice('Device deactivated.');await loadOne('licenses');await loadDevices();void loadOne('activity');}},({rotate:'Could not rotate activation key. Please try again.',revoke:'Failed to revoke license.',upgrade:'Failed to upgrade license.',deactivate:'Failed to deactivate device.'} as Record<string,string>)[modal!])}>{busy?({rotate:'Rotating…',revoke:'Revoking…',upgrade:'Upgrading…',deactivate:'Deactivating…'} as Record<string,string>)[modal!]:({rotate:'Rotate key',revoke:'Revoke license',upgrade:'Upgrade',deactivate:'Deactivate'} as Record<string,string>)[modal!]}</button></div></>}
    </div></div>}
  </div>;
}
const root=document.getElementById('root');
if(root)createRoot(root).render(<React.StrictMode><App/></React.StrictMode>);
