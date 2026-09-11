# List

List To Array: 1cff1b95ab6ddae32faa3efe0d95a820dbfdc164

`src/include/nodes/pg_list.h`

## Struct

```c
typedef union ListCell
{
	void	   *ptr_value;
	int			int_value;
	Oid			oid_value;
	TransactionId xid_value;
} ListCell;

typedef struct List
{
	NodeTag		type;			/* T_List, T_IntList, T_OidList, or T_XidList */
	int			length;			/* number of elements currently present */
	int			max_length;		/* allocated length of elements[] */
	ListCell   *elements;		/* re-allocatable array of cells */
	/* We may allocate some cells along with the List header: */
	ListCell	initial_elements[FLEXIBLE_ARRAY_MEMBER];
	/* If elements == initial_elements, it's not a separate allocation */
} List;

/*
 * The *only* valid representation of an empty list is NIL; in other
 * words, a non-NIL list is guaranteed to have length >= 1.
 */
#define NIL						((List *) NULL)
```

## Inline Functions

```c
/* Fetch address of list's first cell; NULL if empty list */
static inline ListCell *
list_head(const List *l)
{
	return l ? &l->elements[0] : NULL;
}

/* Fetch address of list's last cell; NULL if empty list */
static inline ListCell *
list_tail(const List *l)
{
	return l ? &l->elements[l->length - 1] : NULL;
}

/*
 * Locate the n'th cell (counting from 0) of the list.
 * It is an assertion failure if there is no such cell.
 */
static inline ListCell *
list_nth_cell(const List *list, int n)
{
	Assert(list != NIL);
	Assert(n >= 0 && n < list->length);
	return &list->elements[n];
}


/*
 * Get the address of the next cell after "c" within list "l", or NULL if none.
 */
static inline ListCell *
lnext(const List *l, const ListCell *c)
{
	Assert(c >= &l->elements[0] && c < &l->elements[l->length]);
	c++;
	if (c < &l->elements[l->length])
		return (ListCell *) c;
	else
		return NULL;
}

...
```

## Macros

```c
typedef struct ForEachState
{
	const List *l;				/* list we're looping through */
	int			i;				/* current element index */
} ForEachState;

#define foreach(cell, lst)	\
	for (ForEachState cell##__state = {(lst), 0}; \   /* ## 是预处理器的「粘接」运算符 */
		 (cell##__state.l != NIL && \
		  cell##__state.i < cell##__state.l->length) ? \
		 (cell = &cell##__state.l->elements[cell##__state.i], true) : \
		 (cell = NULL, false); \
		 cell##__state.i++)
```

## Functions

`src/backend/nodes/list.c`

```c
static List *new_list(NodeTag type, int min_size)
static void enlarge_list(List *list, int min_size)
extern pg_nodiscard List *lappend(List *list, void *datum);
extern pg_nodiscard List *lcons(void *datum, List *list);
extern bool list_member(const List *list, const void *datum);
extern pg_nodiscard List *list_delete(List *list, void *datum);
extern void list_free(List *list);
extern void list_sort(List *list, list_sort_comparator cmp);
...
```
