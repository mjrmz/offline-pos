import React, {useEffect,useState} from 'react';
import {createRoot} from 'react-dom/client';
import './style.css';

const base = import.meta.env.VITE_LICENSE_API_URL ?? 'http://localhost:3000';
type Row = Record<string, unknown>;
async function api(path:string, method='GET', data?:unknown):Promise<any> {
  const response=await fetch(`${base}${path}`,{method,credentials:'include',headers:{'Content-Type':'application/json'},body:data?JSON.stringify(data):undefined});
  const parsed=await response.json();
  if(!response.ok) throw Error(parsed.error ?? 'Request failed');
  return parsed;
}
export function App(){
  const [user,setUser]=useState(''); const [username,setUsername]=useState(''); const [password,setPassword]=useState('');
  const [customers,setCustomers]=useState<Row[]>([]); const [licenses,setLicenses]=useState<Row[]>([]); const [events,setEvents]=useState<Row[]>([]);
  const [plans,setPlans]=useState<Row[]>([]); const [devices,setDevices]=useState<Row[]>([]);
  const [businessName,setBusinessName]=useState(''); const [customerId,setCustomerId]=useState(''); const [planId,setPlanId]=useState('non_bir');
  const [maxDevices,setMaxDevices]=useState(1); const [maxReactivations,setMaxReactivations]=useState(3);
  const [key,setKey]=useState(''); const [error,setError]=useState('');
  const load=async()=>{const [c,l,e,p]=await Promise.all([api('/admin/customers'),api('/admin/licenses'),api('/admin/activation-events'),api('/admin/plans')]);setCustomers(c);setLicenses(l);setEvents(e);setPlans(p);};
  useEffect(()=>{api('/admin/me').then(x=>{setUser(x.user);return load();}).catch(()=>{});},[]);
  const run=async(action:()=>Promise<void>)=>{setError('');try{await action();}catch(e){setError(e instanceof Error?e.message:'Request failed');}};
  if(!user)return <main><h1>MASD Licensing Admin</h1><form onSubmit={e=>{e.preventDefault();void run(async()=>{const x=await api('/admin/login','POST',{username,password});setUser(x.user);setPassword('');await load();});}}><input aria-label="Username" value={username} onChange={e=>setUsername(e.target.value)}/><input aria-label="Password" type="password" value={password} onChange={e=>setPassword(e.target.value)}/><button>Log in</button></form><p role="alert">{error}</p></main>;
  return <main><header><h1>MASD Licensing Admin</h1><button onClick={()=>void run(async()=>{await api('/admin/logout','POST');setUser('');})}>Log out</button></header><p role="alert">{error}</p>
    <section><h2>Customers</h2><form onSubmit={e=>{e.preventDefault();void run(async()=>{await api('/admin/customers','POST',{businessName});setBusinessName('');await load();});}}><input aria-label="Business name" value={businessName} onChange={e=>setBusinessName(e.target.value)}/><button>Create customer</button></form><ul>{customers.map(c=><li key={String(c.id)}>{String(c.business_name)} — {String(c.id)}</li>)}</ul></section>
    <section><h2>Issue license</h2><form onSubmit={e=>{e.preventDefault();void run(async()=>{const x=await api('/admin/licenses','POST',{customerId,planId,maxDevices,maxReactivations});setKey(x.activationKey);await load();});}}><label>Customer <select value={customerId} onChange={e=>setCustomerId(e.target.value)} required><option value="">Select</option>{customers.map(c=><option key={String(c.id)} value={String(c.id)}>{String(c.business_name)}</option>)}</select></label><label>Plan <select value={planId} onChange={e=>setPlanId(e.target.value)}>{plans.map(p=><option key={String(p.id)} value={String(p.id)}>{String(p.display_name)}</option>)}</select></label><label>Devices <input type="number" min="1" value={maxDevices} onChange={e=>setMaxDevices(Number(e.target.value))}/></label><label>Reactivations <input type="number" min="0" value={maxReactivations} onChange={e=>setMaxReactivations(Number(e.target.value))}/></label><button>Issue</button></form>{key&&<p>Copy this activation key now. It is shown once: <strong>{key}</strong></p>}</section>
    <section><h2>Licenses</h2>{licenses.map(l=><article key={String(l.id)}><b>{String(l.business_name)}</b> — {String(l.plan_id)} — {String(l.status)} — {String(l.active_devices)}/{String(l.max_devices)} devices <button onClick={()=>void run(async()=>setDevices(await api(`/admin/licenses/${l.id}/devices`)))}>View devices</button> <button disabled={l.status==='revoked'} onClick={()=>void run(async()=>{await api(`/admin/licenses/${l.id}/revoke`,'POST');await load();})}>Revoke</button> <button disabled={l.status==='revoked' || l.plan_id==='bir_ready'} onClick={()=>void run(async()=>{await api(`/admin/licenses/${l.id}/edition`,'POST',{edition:'bir_ready'});await load();})}>Upgrade to BIR-ready</button><small>{String(l.id)}</small></article>)}<h3>Selected devices</h3>{devices.map(d=><article key={String(d.id)}>{String(d.device_fingerprint).slice(0,12)}… — {String(d.status)} <button disabled={d.status!=='active'} onClick={()=>void run(async()=>{await api(`/admin/devices/${d.id}/deactivate`,'POST');await load();setDevices(await api(`/admin/licenses/${d.license_id}/devices`));})}>Deactivate</button></article>)}</section>
    <section><h2>Activation events</h2>{events.map(e=><article key={String(e.id)}>{String(e.created_at)} — {String(e.event_type)} — {String(e.reason ?? '')} — {String(e.license_id ?? '')}</article>)}</section>
  </main>;
}
const root = document.getElementById('root');
if (root) createRoot(root).render(<React.StrictMode><App/></React.StrictMode>);
