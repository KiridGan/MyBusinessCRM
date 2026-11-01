(() => {
'use strict';
// All editable inputs have at most two decimal places. Avoid binary floating
// point multiplication (e.g. 1.01 hours × 0.50 must round to 0.51, like numeric).
function minor(value){const text=String(value??'0');if(!/^\d+(\.\d{1,2})?$/.test(text))throw Error('invalid-number');const [whole,fraction='']=text.split('.');return BigInt(whole)*100n+BigInt(fraction.padEnd(2,'0'))}
function amountCents(row){return row.pricing_mode==='fixed'?minor(row.fixed_amount):(minor(row.hours)*minor(row.hourly_rate)+50n)/100n}
function extraFor(orderId,rows){return rows.filter(r=>r.order_id===orderId&&r.accounting_mode==='additional').reduce((sum,r)=>sum+Number(minor(r.amount)),0)/100}
function create(runtime){const client=runtime.store.client,base=CRMEquipmentCore.create(runtime.store);const check=r=>{if(r.error)throw r.error;return r.data};
async function saveContractor(row,edit){let q=edit?client.from('order_contractors').update(row).eq('id',row.id).eq('user_id',row.user_id):client.from('order_contractors').insert(row);const result=await q.select('*').single();if(!edit&&result.error?.code==='23505'){const existing=check(await client.from('order_contractors').select('*').eq('id',row.id).eq('user_id',row.user_id).single());if(Object.keys(row).every(k=>['hours','hourly_rate','fixed_amount'].includes(k)?Number(existing[k])===Number(row[k]):existing[k]===row[k]))return existing}return check(result)}
async function saveOwned(row){return check(await client.from('equipment_order_links').upsert(row,{onConflict:'order_id,equipment_id'}).select('*').single())}
return {all:base.all,remove:base.remove,saveContractor,saveOwned};}
globalThis.CRMParticipationCore={minor,amountCents,extraFor,create};
})();
