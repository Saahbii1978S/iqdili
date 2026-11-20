do $comment_test$
begin
  update public.post_comments
  set post_id = 2
  where body = 'Edited parent';
  raise exception 'Trigger allowed a member to move a comment to another post';
exception when raise_exception then
  if sqlerrm <> 'Comment ownership, target, parent and creation time are immutable' then
    raise;
  end if;
end;
$comment_test$;

do $comment_test$
begin
  update public.post_comments
  set id = id + 10000
  where body = 'Edited parent';
  raise exception 'Trigger allowed a member to change the comment id';
exception when raise_exception then
  if sqlerrm <> 'Comment id, ownership, target, parent and creation time are immutable' then
    raise;
  end if;
end;
$comment_test$;