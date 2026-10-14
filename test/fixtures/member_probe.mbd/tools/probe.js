async function probe() {
  var me = await host.member.me();
  var can = await host.member.can('use');
  var people = await host.member.people();
  return { me: me, can: can, people: people.length };
}
